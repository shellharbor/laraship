#!/usr/bin/env python3
"""Plan, prepare, apply and recover reviewed Compose application upgrades."""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import uuid

from upgrade_model import (ASSETS, UpgradeError, choose, copy_source, digest, discard, excluded, files,
                           packages, read_json, recipe, tree_hash, validate_composer, version, write_json)
from upgrade_runtime import Runner, project_lock

ROOT = Path(__file__).resolve().parents[1]
WWW = Path('/var/www')
ROLES = ('php', 'artisan', 'composer', 'cron', 'queue', 'horizon')


def git_environment(**settings) -> dict:
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_TERMINAL_PROMPT='0', GIT_OPTIONAL_LOCKS='0', **settings)
    return environment


def git(runner: Runner, app: Path, *arguments: str, environment: dict | None = None) -> bytes:
    return runner.run(['git', '-c', f'safe.directory={app}', '-c', 'core.hooksPath=/dev/null',
        '-c', 'core.fsmonitor=false', '-c', 'core.autocrlf=false', '-C', str(app), *arguments],
        env=environment if environment is not None else git_environment())


def own(path: Path) -> None:
    for parent, directories, names in os.walk(path, followlinks=False):
        os.chown(parent, 1000, 1000)
        for name in directories + names:
            os.chown(Path(parent) / name, 1000, 1000, follow_symlinks=False)


def toolkit_hash() -> str:
    result = hashlib.sha256()
    for name in ('upgrade.py', 'upgrade_model.py', 'upgrade_runtime.py', 'upgrade-policy.json'):
        result.update((ROOT / 'lib' / name).read_bytes())
    context = ROOT / 'laravel/.docker/php'
    for name in files(context, source=False):
        result.update(name.as_posix().encode() + digest(context / name).encode())
    result.update((ROOT / 'versions.env').read_bytes())
    return result.hexdigest()


class Project:
    def __init__(self, slug: str, runner: Runner, www: Path = WWW):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', slug) or slug.lower() == 'nginxproxy':
            raise UpgradeError('Use a non-reserved project slug with at most 63 letters, digits, underscores or hyphens')
        self.slug, self.runner, self.path = slug, runner, www / slug
        self.app = self.path / 'public_html'
        for path in (www, self.path, self.app):
            if path.is_symlink() or not path.is_dir():
                raise UpgradeError('Expected a real LaraShip project directory, without symlink parents')
        for relative in ('.docker', '.docker/php', '.config', 'public_html/vendor', 'public_html/storage',
                         'public_html/bootstrap', 'public_html/bootstrap/cache', 'public_html/public'):
            path = self.path / relative
            if path.is_symlink():
                raise UpgradeError('Managed application/build directories must not be symbolic links')
        check_php_context(self.path / '.docker/php')
        self.config = json.loads(runner.compose(self.path, 'config', '--format', 'json'))
        self.services = self.config['services']
        if not all(name in self.services for name in ('php', 'artisan', 'composer', 'nginx')):
            raise UpgradeError('This upgrader requires a LaraShip Compose project')
        override = self.path / 'docker-compose.override.yml'
        if override.exists() and not read_json(override).get('x-laraship-upgrade'):
            raise UpgradeError('Custom Compose overrides require an application-specific upgrade workflow')
        if (self.path / 'docker-compose.override.yaml').exists() or os.environ.get('COMPOSE_FILE'):
            raise UpgradeError('Unset COMPOSE_FILE and use the standard LaraShip Compose files')
        self.roles = [name for name in ROLES if name in self.services]
        for role in self.roles:
            service = self.services[role]
            build = service.get('build', {})
            if not isinstance(build, dict) or Path(build.get('context', '')).resolve() != (self.path / '.docker/php').resolve():
                raise UpgradeError('All PHP roles must use the standard project PHP build context')
            if build.get('dockerfile') not in ('php82.Dockerfile', 'php83.Dockerfile') or build.get('args'):
                raise UpgradeError('Custom PHP build recipes/arguments require manual review')
            mounts = service.get('volumes', [])
            root_mounts = [mount for mount in mounts if mount.get('target') == '/var/www/html']
            if len(root_mounts) != 1 or root_mounts[0].get('type') != 'bind' or Path(root_mounts[0].get('source', '')).resolve() != self.app.resolve():
                raise UpgradeError('Every PHP role must bind the project application at /var/www/html')
            for mount in mounts:
                target = mount.get('target', '')
                if target.startswith('/var/www/html/'):
                    raise UpgradeError('Nested application mounts require an application-specific upgrade workflow')
        source_php = runner.compose(self.path, 'ps', '--status', 'running', '-q', 'php').decode().strip()
        if not re.fullmatch(r'[a-f0-9]{12,64}', source_php):
            raise UpgradeError('Start the project PHP container before inspecting an upgrade')
        self.php_container = source_php
        container = runner.inspect('container', source_php)
        self.php_image = container['Image']
        if not any(mount.get('Type') == 'bind' and mount.get('Destination') == '/var/www/html'
                   and Path(mount.get('Source', '')).resolve() == self.app.resolve() for mount in container.get('Mounts', [])):
            raise UpgradeError('The running PHP container belongs to a different application filesystem')
        self.php = runner.docker('exec', source_php, 'php', '-n', '-r', 'echo PHP_VERSION;', timeout=15).decode().strip()
        version(self.php)
        self.lock = read_json(self.app / 'composer.lock')
        self.current = packages(self.lock)
        self.composer = read_json(self.app / 'composer.json')
        validate_composer(self.composer)
        installed = read_json(self.app / 'vendor/composer/installed.json')
        installed_versions = {item['name']: item['version'] for item in installed.get('packages', [])}
        if installed_versions.get('laravel/framework', '').lstrip('v') != self.current['laravel/framework'].lstrip('v'):
            raise UpgradeError('Installed Laravel does not match composer.lock')
        self.environment = dict(line.split('=', 1) for line in runner.compose(self.path, 'config', '--environment').decode().splitlines() if '=' in line)
        self.repository = (self.app / '.git').exists()
        self.commit = None
        if self.repository:
            if (self.app / '.git').is_symlink() or not (self.app / '.git').is_dir():
                raise UpgradeError('Use the standalone Git clone created by LaraShip; worktrees need a separate migration')
            if git(runner, self.app, 'status', '--porcelain', '--untracked-files=no').strip():
                raise UpgradeError('Commit or revert tracked application changes before upgrading')
            tracked = set(git(runner, self.app, 'ls-files', '-z').decode().split('\0'))
            untracked = {name.as_posix() for name in files(self.app)} - tracked - {'composer.lock', 'package-lock.json'}
            if untracked:
                raise UpgradeError('Untracked or ignored application source must be committed or moved outside the project before upgrading')
            if (self.app / '.gitmodules').exists() or not (self.path / '.deploy-meta').is_file():
                raise UpgradeError('Git upgrades require --repo metadata and no submodules')
            validate_tracked(list(tracked))
            self.commit = git(runner, self.app, 'rev-parse', 'HEAD').decode().strip()
        if (self.app / 'storage/framework/down').exists():
            raise UpgradeError('The project is already in maintenance mode; finish that operation first')

    def fingerprint(self) -> str:
        result = hashlib.sha256(tree_hash(self.app).encode())
        for name in ('docker-compose.yml', 'docker-compose.override.yml', '.env', '.deploy-meta', '.config/php/project.ini'):
            path = self.path / name
            if path.is_symlink():
                raise UpgradeError('Project configuration must not be a symbolic link')
            if path.exists():
                result.update(name.encode() + digest(path).encode())
        for path in sorted(self.app.glob('.env*')):
            if path.is_symlink() or not path.is_file():
                raise UpgradeError('Environment files must be regular files')
            result.update(path.name.encode() + digest(path).encode())
        result.update(tree_hash(self.path / '.docker/php', source=False).encode())
        if (self.path / '.config').exists():
            result.update(tree_hash(self.path / '.config', source=False).encode())
        result.update(tree_hash(self.app / 'vendor', source=False).encode())
        for name in ASSETS:
            path = self.app / name
            if path.is_symlink():
                raise UpgradeError('Generated asset directories must not be symbolic links')
            if path.exists():
                result.update(name.encode() + tree_hash(path, source=False).encode())
        if self.repository:
            result.update(git(self.runner, self.app, 'rev-parse', 'HEAD'))
            for name in ('config', 'HEAD'):
                path = self.app / '.git' / name
                if path.is_symlink() or not path.is_file():
                    raise UpgradeError('Git deployment metadata must be regular files')
                result.update(name.encode() + digest(path).encode())
        return result.hexdigest()

    def plan(self, requested: str | None) -> dict:
        minimum = '12.0'
        for line in (ROOT / 'versions.env').read_text(encoding='utf-8').splitlines():
            if line.startswith('LARAVEL_MIN_VERSION='):
                minimum = line.split('=', 1)[1].strip()
        target = choose(ROOT, self.current, self.php, requested, minimum)
        native = self.environment.get('DB_NATIVE') == 'true'
        if native and 'backup' not in self.services:
            raise UpgradeError('Native database upgrades require the existing backup module for a verified pre-upgrade dump')
        if not native and 'db' not in self.services:
            raise UpgradeError('A project database service or native backup module is required')
        return {'schema': 1, 'slug': self.slug, 'source': {'laravel': self.current['laravel/framework'],
            'php': self.php, 'filament': self.current.get('filament/filament'), 'commit': self.commit},
            'target': target, 'repository': self.repository, 'roles': self.roles,
            'fingerprint': self.fingerprint(), 'toolkit_hash': toolkit_hash(),
            'source_override_id': read_json(self.path / 'docker-compose.override.yml').get('x-laraship-upgrade', {}).get('id') if (self.path / 'docker-compose.override.yml').exists() else None,
            'notes': ['Latest means the reviewed Laravel/Filament branch; Composer resolves its current compatible stable patches.',
                      'Major application and plugin changes require review of the generated patch and successful tests.',
                      'Database schema rollback is separate; failures after migrations retain maintenance.']}


def stage_git(runner: Runner, directory: Path, *arguments: str, **options) -> bytes:
    environment = git_environment(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
    return runner.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.autocrlf=false',
        '--git-dir', str(directory / 'git/.git'), '--work-tree', str(directory / 'candidate'), *arguments], env=environment, **options)


def check_php_context(path: Path) -> None:
    canonical = ROOT / 'laravel/.docker/php'
    allowed = {item.name for item in canonical.iterdir() if item.is_file()}
    for item in path.iterdir():
        if item.is_symlink() or not item.is_file() or item.name not in allowed:
            raise UpgradeError('Custom PHP build-context files require manual upgrade review')
        if item.name.endswith('.Dockerfile'):
            def normalized(text):
                result = []
                for line in text.splitlines():
                    if 'security-policy.php' in line:
                        continue
                    if line.startswith('FROM php:'):
                        line = 'FROM php:REVIEWED AS build'
                    result.append(line.rstrip().rstrip('\\').rstrip())
                return result
            if normalized(item.read_text()) != normalized((canonical / item.name).read_text()):
                raise UpgradeError('Custom PHP Dockerfiles need a reviewed application-specific upgrade')
        elif item.name == '.dockerignore':
            if item.read_text().replace('!security-policy.php\n', '') != (canonical / item.name).read_text().replace('!security-policy.php\n', ''):
                raise UpgradeError('Custom PHP build exclusions require manual review')
        elif item.read_bytes() != (canonical / item.name).read_bytes():
            raise UpgradeError('Custom PHP build scripts require manual review')


def validate_tracked(names: list[str]) -> None:
    for name in names:
        path = Path(name)
        if not name:
            continue
        if path.parts[0] in ('vendor', 'node_modules') or any(path == Path(asset) or Path(asset) in path.parents for asset in ASSETS) \
                or path.parts[0].startswith('.env') and path.name != '.env.example' \
                or path.parts[0] == 'storage' and path.name != '.gitignore' \
                or path.parts[:2] == ('bootstrap', 'cache') and path.suffix == '.php' or name == '.gitmodules':
            raise UpgradeError('Git must not track environment secrets, runtime data, dependencies or generated build artifacts')


def load_state(path: Path, slug: str) -> tuple[Path, dict]:
    if not path.is_absolute() or path.name != 'plan.json':
        raise UpgradeError('Select an absolute saved plan.json path')
    directory = path.parent
    if not re.fullmatch(r'[a-f0-9]{32}', directory.name) or directory.parent != WWW / slug / '.laraship-upgrades':
        raise UpgradeError('Saved plan is outside this project upgrade workspace')
    for part in (path, directory, directory.parent):
        if part.is_symlink() or part.stat().st_uid != os.geteuid() or part.stat().st_mode & 0o077:
            raise UpgradeError('Saved plan/workspace must be private and owned by the operator')
    state = read_json(path)
    if state.get('schema') != 1 or state.get('slug') != slug or state.get('id') != directory.name:
        raise UpgradeError('Saved plan identity is invalid')
    if state.get('toolkit_hash') != toolkit_hash():
        raise UpgradeError('The toolkit changed; prepare a new upgrade plan')
    if not isinstance(state.get('roles'), list) or 'php' not in state['roles'] or not all(role in ROLES for role in state['roles']):
        raise UpgradeError('Saved plan contains invalid PHP roles; database services cannot be changed')
    return directory, state


def checkpoint(directory: Path, state: dict, status: str | None = None) -> None:
    if status is not None:
        state['status'] = status
    write_json(directory / 'plan.json', state)


def check_image(runner: Runner, image: str) -> None:
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image):
        raise UpgradeError('A prepared runtime must be an immutable local image ID')
    runner.docker('image', 'inspect', image)
    runner.docker('run', '--rm', '--network', 'none', '--read-only', '--entrypoint', 'php', image,
        '-r', (ROOT / 'laravel/.docker/php/security-policy.php').read_text(encoding='utf-8').removeprefix('<?php')
        + '\nlaraship_security_main([]);')


def prepare(project: Project, requested: str | None, test_command: str | None, health: str) -> tuple[Path, dict]:
    state = project.plan(requested)
    owner = uuid.uuid4().hex
    base = project.path / '.laraship-upgrades'
    if base.is_symlink():
        raise UpgradeError('Refusing a symbolic link upgrade workspace')
    base.mkdir(mode=0o700, exist_ok=True)
    if base.stat().st_uid != os.geteuid() or base.stat().st_mode & 0o077:
        raise UpgradeError('Upgrade workspace must be private and owned by the operator')
    directory = base / owner
    directory.mkdir(mode=0o700)
    state.update(id=owner, status='preparing', health_path=health,
        test_command=shlex.split(test_command) if test_command else ['php', 'artisan', 'test', '--stop-on-failure'])
    checkpoint(directory, state)
    project.runner.owner = owner
    try:
        app = directory / 'candidate'
        copy_source(project.app, app)
        project.runner.run(['git', 'init', '--quiet', str(directory / 'git')])
        (directory / 'git/.git/info/exclude').write_text(
            '/vendor/\n/node_modules/\n/storage/\n/public/build/\n/public/storage\n/public/hot\n'
            '/public/css/filament/\n/public/js/filament/\n/public/fonts/filament/\n'
            '/bootstrap/cache/*.php\n/.env*\n/.phpunit.cache/\n/.phpunit.result.cache\n/coverage/\n', encoding='utf-8')
        if project.repository:
            tracked = [name for name in git(project.runner, project.app, 'ls-files', '-z').decode().split('\0')
                       if name and not excluded(Path(name)) and (app / name).exists()]
            for offset in range(0, len(tracked), 200):
                stage_git(project.runner, directory, 'add', '--force', '--', *tracked[offset:offset + 200])
        else:
            stage_git(project.runner, directory, 'add', '--all')
            stage_git(project.runner, directory, 'add', '--force', 'composer.json', 'composer.lock')
        stage_git(project.runner, directory, '-c', 'user.name=LaraShip Upgrade', '-c', 'user.email=upgrade@localhost', 'commit', '--quiet', '-m', 'Original application snapshot')
        write_json(app / 'composer.json', recipe(project.composer, state['target']))
        own(app)
        source_branch = '.'.join(project.php.split('.')[:2])
        print('Building the reviewed PHP runtime; the live project remains available', flush=True)
        state['baseline_image'] = project.runner.build(ROOT, source_branch, f'laraship-upgrade:{owner}-baseline', directory)
        target_branch = state['target']['php_branch']
        state['target_image'] = state['baseline_image'] if target_branch == source_branch else project.runner.build(ROOT, target_branch, f'laraship-upgrade:{owner}-target', directory)
        state['baseline_branch'] = source_branch
        check_image(project.runner, state['baseline_image'])
        check_image(project.runner, state['target_image'])
        values = checked_environment(project.runner, project.path, directory, state['baseline_image'])
        state['build_environment'] = {key: value for key, value in values.items()
                                      if key.startswith('VITE_') or key in ('APP_NAME', 'APP_URL', 'ASSET_URL')}
        checkpoint(directory, state)
        verify(project, directory, state)
    except BaseException:
        checkpoint(directory, state, 'preparation_failed')
        print(f'Preparation stopped. Private candidate and plan: {directory / "plan.json"}', file=sys.stderr)
        raise
    return directory, state


def verify(project: Project, directory: Path, state: dict) -> None:
    if project.fingerprint() != state['fingerprint']:
        raise UpgradeError('The live project changed after planning; prepare a new candidate')
    if state['status'] not in ('preparing', 'preparation_failed', 'prepared'):
        raise UpgradeError('Only a candidate which has not been applied can be verified')
    # Invalidate any old seal before commands can alter a previously prepared candidate.
    checkpoint(directory, state, 'preparation_failed')
    app, runner = directory / 'candidate', project.runner
    runner.owner = state['id']
    validate_composer(read_json(app / 'composer.json'))
    if any(app.glob('.env*')):
        raise UpgradeError('The private candidate must not contain environment files; tests use isolated synthetic settings')
    own(app)
    for relative in ('storage/framework/cache/data', 'storage/framework/sessions', 'storage/framework/views', 'storage/logs', 'bootstrap/cache'):
        (app / relative).mkdir(parents=True, exist_ok=True)
    own(app)
    image = state['target_image']
    check_image(runner, image)
    print('Resolving candidate dependencies without installation, scripts or plugins', flush=True)
    runner.candidate(app, image, ['composer', 'update', '--no-install', '--no-scripts', '--no-plugins',
        '--prefer-dist', '--no-progress', '--no-interaction'], network=True)
    runner.candidate(app, image, ['php', '/usr/local/share/laraship/security-policy.php', '/var/www/html/composer.lock'])
    resolved = packages(read_json(app / 'composer.lock'))
    if version(resolved['laravel/framework'])[0] != state['target']['laravel_major']:
        raise UpgradeError('Resolved Laravel does not match the selected upgrade target')
    if state['target']['filament_major'] and version(resolved.get('filament/filament', '0.0.0'))[0] != 5:
        raise UpgradeError('Resolved Filament does not match the reviewed target')
    print('Installing the verified candidate lock without application scripts', flush=True)
    runner.candidate(app, image, ['composer', 'install', '--no-scripts', '--prefer-dist', '--no-progress', '--no-interaction'], network=True, timeout=1200)
    if state['target']['filament_upgrade'] and not state.get('filament_recipe_applied'):
        print('Applying the official Filament migration to the candidate app directory', flush=True)
        runner.candidate(app, image, ['php', 'vendor/bin/filament-v5', 'app'])
        config = read_json(app / 'composer.json')
        config.get('require-dev', {}).pop('filament/upgrade', None)
        write_json(app / 'composer.json', config)
        own(app)
        runner.candidate(app, image, ['composer', 'update', '--no-scripts', '--prefer-dist', '--no-progress', '--no-interaction'], network=True)
        state['filament_recipe_applied'] = True
        checkpoint(directory, state)
    for event in ('post-autoload-dump', 'post-update-cmd'):
        if event in read_json(app / 'composer.json').get('scripts', {}):
            runner.candidate(app, image, ['composer', 'run-script', event, '--no-interaction'])
    runner.candidate(app, image, ['php', 'artisan', 'package:discover', '--no-interaction'])
    if state['target']['filament_major']:
        runner.candidate(app, image, ['php', 'artisan', 'filament:upgrade', '--no-interaction'])
    if (app / 'package.json').exists():
        package = read_json(app / 'package.json')
        if package.get('scripts', {}).get('build'):
            print('Building frontend assets with the reviewed Node runtime', flush=True)
            node = state['target']['node_image']
            runner.docker('pull', node, timeout=300)
            if not (app / 'package-lock.json').exists():
                runner.candidate(app, node, ['npm', 'install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'], network=True)
            runner.candidate(app, node, ['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], network=True)
            runner.candidate(app, node, ['npm', 'run', 'build'], environment=state.get('build_environment'))
    if (project.app / 'public/build').exists() and not (app / 'public/build').is_dir():
        raise UpgradeError('Rebuild the existing frontend assets in the private candidate before applying')
    command = state['test_command']
    if not command or command[0].startswith('-') or not (app / 'tests').is_dir():
        raise UpgradeError('An application test suite and a nonempty test command are required')
    print('Running candidate application tests with isolated testing settings and no network', flush=True)
    runner.candidate(app, image, command)
    runner.candidate(app, image, ['composer', 'install', '--no-dev', '--no-scripts', '--prefer-dist', '--no-progress', '--no-interaction'], network=True)
    runner.candidate(app, image, ['composer', 'check-platform-reqs', '--no-dev'])
    runner.candidate(app, image, ['php', '/usr/local/share/laraship/security-policy.php', '/var/www/html/composer.lock'])
    validate_composer(read_json(app / 'composer.json'))
    if any(app.glob('.env*')):
        raise UpgradeError('Candidate commands created environment files; remove them and verify again')
    for path in list((app / 'bootstrap/cache').glob('*.php')):
        path.unlink()
    discard(app / 'storage', directory)
    discard(app / 'node_modules', directory)
    discard(app / '.phpunit.cache', directory)
    discard(app / '.phpunit.result.cache', directory)
    discard(app / 'coverage', directory)
    stage_git(runner, directory, 'add', '--all')
    stage_git(runner, directory, 'add', '--force', 'composer.json', 'composer.lock')
    if (app / 'package-lock.json').exists():
        stage_git(runner, directory, 'add', '--force', 'package-lock.json')
    descriptor = os.open(directory / 'application.patch', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        stage_git(runner, directory, 'diff', '--cached', '--binary', '--no-ext-diff', 'HEAD', output=output)
    resolved = packages(read_json(app / 'composer.lock'))
    actual = version(resolved['laravel/framework'])
    selected = version(state['target']['laravel_constraint'].lstrip('^'))
    if actual[0] != selected[0] or actual < selected or not state['target']['laravel_constraint'].startswith('^') and actual != selected:
        raise UpgradeError('The final candidate changed the selected Laravel target')
    if state['target']['filament_major'] and version(resolved.get('filament/filament', '0.0.0'))[0] != state['target']['filament_major']:
        raise UpgradeError('The final candidate changed the selected Filament target')
    state.update(candidate_hash=tree_hash(app, source=False), source_hash=tree_hash(app),
        resolved={'laravel': resolved['laravel/framework'], 'filament': resolved.get('filament/filament')})
    state['git_manifest'] = index_manifest(stage_git(runner, directory, 'ls-files', '--stage', '-z'))
    if project.fingerprint() != state['fingerprint']:
        raise UpgradeError('The live project changed during preparation; candidate cannot be applied')
    checkpoint(directory, state, 'prepared')
    print(f'Candidate passed. Review {directory / "application.patch"}; saved plan: {directory / "plan.json"}', flush=True)


def index_manifest(data: bytes, *, tree: bool = False) -> dict:
    result = {}
    for row in data.decode('utf-8').split('\0'):
        if not row:
            continue
        header, name = row.split('\t', 1)
        values = header.split()
        if not excluded(Path(name)):
            result[name] = [values[0], values[2] if tree else values[1]]
    return result


def managed_override(project: Path, state: dict, image: str, branch: str) -> None:
    value = {'x-laraship-upgrade': {'id': state['id'], 'php_branch': branch}, 'services': {}}
    for role in state['roles']:
        value['services'][role] = {'image': image, 'pull_policy': 'never',
            'build': {'context': './.docker/php', 'dockerfile': f'php{branch.replace(".", "")}.Dockerfile'}}
    write_json(project / 'docker-compose.override.yml', value)


def app_environment(runner: Runner, project: Path, directory: Path, image: str, *, uncached: bool = False) -> dict:
    program = r'''require 'vendor/autoload.php';
$values = Dotenv\Dotenv::createArrayBacked(getcwd())->safeLoad();
$keys = ['APP_NAME','APP_URL','ASSET_URL'];
$values = array_filter($values, fn($key) => in_array($key, $keys, true) || str_starts_with($key, 'VITE_'), ARRAY_FILTER_USE_KEY);
$app = require 'bootstrap/app.php'; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$connection = $app['db']->connection()->getConfig();
$values['DB_CONFIG_HASH'] = hash('sha256', json_encode($connection, JSON_THROW_ON_ERROR));
$values['APP_KEY_HASH'] = hash('sha256', json_encode([config('app.key'), config('app.cipher'), config('app.previous_keys', [])], JSON_THROW_ON_ERROR));
foreach (['driver'=>'DB_CONNECTION','host'=>'DB_HOST','port'=>'DB_PORT','database'=>'DB_DATABASE','username'=>'DB_USERNAME','password'=>'DB_PASSWORD'] as $key=>$name) {
    if (!is_scalar($connection[$key] ?? null)) { throw new RuntimeException('Unsupported database setting'); }
    $values[$name] = (string) $connection[$key];
}
echo json_encode($values, JSON_THROW_ON_ERROR);'''
    values = json.loads(runner.live(project, directory, image, ['php', '-r', program],
        environment={'APP_CONFIG_CACHE': '/tmp/laraship-uncached-config.php'} if uncached else None))
    if not all(isinstance(value, str) and not any(char in value for char in '\r\n\0') for value in values.values()):
        raise UpgradeError('Database settings contain unsupported control characters')
    return values


def checked_environment(runner: Runner, project: Path, directory: Path, image: str) -> dict:
    values = app_environment(runner, project, directory, image)
    fresh = app_environment(runner, project, directory, image, uncached=True)
    if values['DB_CONFIG_HASH'] != fresh['DB_CONFIG_HASH']:
        raise UpgradeError('Cached and uncached database settings differ; reconcile application configuration before upgrading')
    if values['APP_KEY_HASH'] != fresh['APP_KEY_HASH']:
        raise UpgradeError('Cached and uncached encryption settings differ; reconcile APP_KEY/cipher configuration before upgrading')
    return values


def database_backup(project: Path, directory: Path, state: dict, runner: Runner) -> dict:
    configuration = json.loads(runner.compose(project, 'config', '--format', 'json'))
    environment = dict(line.split('=', 1) for line in runner.compose(project, 'config', '--environment').decode().splitlines() if '=' in line)
    values = checked_environment(runner, project, directory, state['baseline_image'])
    if environment.get('DB_NATIVE') == 'true':
        backup_env = configuration['services'].get('backup', {}).get('environment', {})
        expected_type = {'pgsql': 'postgres', 'mysql': 'mysql'}.get(values.get('DB_CONNECTION'))
        if not expected_type or backup_env.get('DB_TYPE') != expected_type or any(str(backup_env.get(key, '')) != values.get(other) for key, other in (
                ('DB_HOST', 'DB_HOST'), ('DB_PORT', 'DB_PORT'), ('DB_NAME', 'DB_DATABASE'), ('DB_USER', 'DB_USERNAME'))):
            raise UpgradeError('Native backup configuration does not match the actual application database')
        output = runner.compose(project, 'exec', '-T', 'backup', '/bin/sh', '/scripts/dump.sh', timeout=900).decode().splitlines()
        filename = Path(output[-1]).name if output else ''
        if not re.fullmatch(r'[A-Za-z0-9_-]+\.(?:dump|sql\.gz)', filename):
            raise UpgradeError('Backup module returned an invalid dump name')
        source = project / 'backups' / filename
        if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
            raise UpgradeError('Backup module did not create a regular nonempty dump')
        target = directory / filename
        shutil.copyfile(source, target)
        target.chmod(0o600)
        kind = 'pgsql' if filename.endswith('.dump') else 'mysql'
        if kind == 'pgsql':
            runner.compose(project, 'run', '--rm', '--no-deps', '-T', '--entrypoint', 'pg_restore',
                           'backup', '--list', f'/backups/{filename}')
        else:
            with gzip.open(target, 'rb') as stream:
                if not stream.read(1):
                    raise UpgradeError('Backup module produced empty SQL')
                for _ in iter(lambda: stream.read(1024 * 1024), b''):
                    pass
    else:
        if 'db' not in configuration['services']:
            raise UpgradeError('The project database service is missing')
        identifier = runner.compose(project, 'ps', '--status', 'running', '-q', 'db').decode().strip()
        if not re.fullmatch(r'[a-f0-9]{12,64}', identifier):
            raise UpgradeError('The project database is not running')
        kind = values.get('DB_CONNECTION')
        if kind not in ('pgsql', 'mysql'):
            raise UpgradeError('Only PostgreSQL/MySQL application databases are supported')
        if values.get('DB_HOST') != 'db' or values.get('DB_PORT', '') not in ('', '5432' if kind == 'pgsql' else '3306'):
            raise UpgradeError('The application database is not the project database service; automatic upgrade backup refused')
        target = directory / ('database.dump' if kind == 'pgsql' else 'database.sql')
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        # Password is stdin only; private option files exist only in the database container.
        if kind == 'pgsql':
            script = r'''set -eu; umask 077; work=$(mktemp -d /tmp/laraship-dump.XXXXXX)
trap 'rm -rf "$work"' 0; trap 'exit 1' 1 2 15
IFS= read -r password
escaped=$(printf '%s' "$password" | sed 's/\\/\\\\/g; s/:/\\:/g')
printf '127.0.0.1:5432:*:*:%s\n' "$escaped" > "$work/pgpass"
PGPASSFILE="$work/pgpass" pg_dump --host=127.0.0.1 --username="$1" --dbname="$2" --format=custom --lock-wait-timeout=30s'''
        else:
            script = r'''set -eu; umask 077; work=$(mktemp -d /tmp/laraship-dump.XXXXXX)
trap 'rm -rf "$work"' 0; trap 'exit 1' 1 2 15
IFS= read -r password
escaped=$(printf '%s' "$password" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '[client]\npassword="%s"\n' "$escaped" > "$work/client.cnf"
mysqldump --defaults-extra-file="$work/client.cnf" --host=127.0.0.1 --user="$1" --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --triggers --events -- "$2"'''
        try:
            with os.fdopen(descriptor, 'wb') as output:
                runner.docker('exec', '--interactive', identifier, 'sh', '-ec', script, 'dump',
                    values['DB_USERNAME'], values['DB_DATABASE'], data=(values['DB_PASSWORD'] + '\n').encode(),
                    output=output, timeout=900)
            if target.stat().st_size == 0:
                raise UpgradeError('Database dump is empty')
            if kind == 'pgsql':
                with target.open('rb') as stream:
                    if stream.read(5) != b'PGDMP':
                        raise UpgradeError('Invalid PostgreSQL dump header')
                with target.open('rb') as stream:
                    runner.docker('exec', '--interactive', identifier, 'pg_restore', '--list', input_stream=stream, output=subprocess.DEVNULL)
            else:
                with target.open('rb') as stream:
                    if b'MySQL dump' not in stream.read(512):
                        raise UpgradeError('Invalid MySQL dump header')
        except BaseException:
            target.unlink(missing_ok=True)
            raise
    return {'file': target.name, 'kind': kind, 'sha256': digest(target), 'size': target.stat().st_size}


def maintenance(runner: Runner, project: Path, directory: Path, image: str, *, enable: bool) -> None:
    token_path = directory / 'maintenance-token'
    if enable:
        if not token_path.exists():
            descriptor = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w', encoding='ascii') as output:
                output.write(uuid.uuid4().hex)
        program = r'''require 'vendor/autoload.php'; $app = require 'bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
exit($kernel->call('down', ['--secret' => trim(stream_get_contents(STDIN)), '--retry' => 60]));'''
        runner.live(project, directory, image, ['php', '-r', program], data=token_path.read_bytes())
    else:
        runner.live(project, directory, image, ['php', 'artisan', 'up'])
    down = project / 'public_html/storage/framework/down'
    if enable and (down.is_symlink() or not down.is_file()):
        runner.live(project, directory, image, ['php', 'artisan', 'up'])
        raise UpgradeError('Only file-based Laravel maintenance mode is supported')
    if enable:
        down.chmod(0o600)


def database_ready(runner: Runner, project: Path, directory: Path, image: str) -> None:
    runner.live(project, directory, image, ['php', '-r', r'''require 'vendor/autoload.php';
$app = require 'bootstrap/app.php'; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
Illuminate\Support\Facades\DB::select('SELECT 1');'''])


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        return None


def http_ready(runner: Runner, project: Path, state: dict) -> None:
    environment = dict(line.split('=', 1) for line in runner.compose(project, 'config', '--environment').decode().splitlines() if '=' in line)
    port = environment.get('SITE_PORT_HTTP', '')
    host = environment.get('SITE_HOST', '')
    if not port.isdecimal() or not 1 <= int(port) <= 65535 or not re.fullmatch(r'[A-Za-z0-9.-]+', host):
        raise UpgradeError('Project HTTP host/port metadata is invalid')
    data = read_json(project / 'public_html/storage/framework/down')
    secret = data.get('secret', '')
    if not re.fullmatch(r'[A-Za-z0-9-]+', secret):
        raise UpgradeError('Maintenance bypass data is unavailable')
    # Laravel 12/13 MaintenanceModeBypassCookie format. Never put its secret in
    # a request URL, where ordinary Nginx access logs would retain it.
    expires = int(time.time()) + 300
    payload = {'expires_at': expires, 'mac': hmac.new(secret.encode(), str(expires).encode(), hashlib.sha256).hexdigest()}
    cookie = base64.b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode('ascii')
    client = build_opener(ProxyHandler({}), NoRedirect())
    headers = {'Host': host, 'Cookie': 'laravel_maintenance=' + cookie}
    if environment.get('AUTH_USER'):
        headers['Authorization'] = 'Basic ' + base64.b64encode((environment['AUTH_USER'] + ':' + environment['AUTH_PASSWORD']).encode()).decode('ascii')
    base = f'http://127.0.0.1:{port}'
    for _ in range(15):
        try:
            with client.open(Request(base + state['health_path'], headers=headers), timeout=5) as response:
                if 200 <= response.status < 300:
                    return
        except (HTTPError, URLError, TimeoutError):
            time.sleep(1)
    raise UpgradeError('The upgraded application did not pass local HTTP readiness; maintenance is retained')


def approve_commit(project: Project, directory: Path, state: dict, commit: str | None) -> None:
    if not project.repository:
        if commit:
            raise UpgradeError('--commit is only valid for --repo applications')
        return
    if not commit or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', commit):
        raise UpgradeError('Commit the prepared patch in the application repository, push it, and provide its full --commit SHA')
    metadata = dict(line.split('=', 1) for line in (project.path / '.deploy-meta').read_text().splitlines() if '=' in line)
    branch = metadata.get('REPO_BRANCH', '')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./-]*', branch) or '..' in branch:
        raise UpgradeError('Deployment branch metadata is invalid')
    environment = git_environment()
    key = metadata.get('DEPLOY_KEY_FILE', '')
    if key:
        path = project.path / key
        if path.is_symlink() or not path.resolve().is_relative_to(project.path.resolve()) or not path.is_file():
            raise UpgradeError('Deploy key metadata is invalid')
        environment['GIT_SSH_COMMAND'] = f'ssh -i {shlex.quote(str(path))} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={shlex.quote(str(project.path / ".config/known_hosts"))}'
    git(project.runner, project.app, 'fetch', '--quiet', 'origin', branch, environment=environment)
    upstream = git(project.runner, project.app, 'rev-parse', 'FETCH_HEAD').decode().strip()
    if upstream != commit:
        raise UpgradeError('The reviewed application commit must be the fetched deployment branch head')
    git(project.runner, project.app, 'merge-base', '--is-ancestor', state['source']['commit'], commit)
    actual = index_manifest(git(project.runner, project.app, 'ls-tree', '-r', '-z', commit), tree=True)
    validate_tracked(git(project.runner, project.app, 'ls-tree', '-r', '--name-only', '-z', commit).decode().split('\0'))
    if actual != state['git_manifest']:
        raise UpgradeError('The upstream application tree differs from the tested candidate; review/re-verify the candidate and commit its exact patch')
    state['approved_commit'] = commit
    checkpoint(directory, state)


def install_php_context(project: Path, directory: Path) -> None:
    destination = project / '.docker/php'
    previous = directory / 'previous_php'
    if not previous.exists():
        os.replace(destination, previous)
    temporary = project / '.docker/php.upgrade-new'
    if temporary.exists():
        raise UpgradeError('A partial PHP context needs recovery before retrying')
    shutil.copytree(ROOT / 'laravel/.docker/php', temporary)
    os.replace(temporary, destination)


def runtime_paths(app: Path) -> list[Path]:
    return [*(Path(path.name) for path in app.glob('.env*')), Path('storage'), Path('public/storage')]


def clear_bootstrap_cache(app: Path) -> None:
    directory = app / 'bootstrap/cache'
    if directory.is_symlink() or not directory.is_dir():
        raise UpgradeError('Expected the standard real bootstrap/cache directory')
    for path in directory.glob('*.php'):
        if not path.is_file() and not path.is_symlink():
            raise UpgradeError('Unexpected generated bootstrap cache entry')
        path.unlink()


def apply_upgrade(directory: Path, state: dict, runner: Runner, commit: str | None) -> None:
    if state['status'] != 'prepared':
        raise UpgradeError('Only an unchanged successfully prepared plan can be applied')
    project = Project(state['slug'], runner)
    if state['roles'] != project.roles:
        raise UpgradeError('The saved PHP roles differ from the project; prepare a new plan')
    app = directory / 'candidate'
    if project.fingerprint() != state['fingerprint'] or tree_hash(app, source=False) != state['candidate_hash']:
        raise UpgradeError('The live project or candidate changed; verify/prepare it again')
    check_image(runner, state['target_image'])
    check_image(runner, state['baseline_image'])
    approve_commit(project, directory, state, commit)
    settings = json.loads(runner.live(project.path, directory, state['baseline_image'], ['php', '-r',
        r'''require 'vendor/autoload.php'; $app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
echo json_encode(['driver' => config('app.maintenance.driver'), 'active' => $app->maintenanceMode()->active()]);''']))
    if settings.get('driver') != 'file' or settings.get('active'):
        raise UpgradeError('Apply requires file-based maintenance and an application not already in maintenance')
    active = project.runner.compose(project.path, 'ps', '--status', 'running', '--services').decode().splitlines()
    running = [role for role in ('php', 'cron', 'queue', 'horizon') if role in state['roles'] and role in active]
    if 'php' not in running:
        raise UpgradeError('The project PHP service stopped after planning')
    state['running_roles'] = running
    checkpoint(directory, state, 'applying')
    try:
        state['maintenance_attempted'] = True
        checkpoint(directory, state)
        maintenance(runner, project.path, directory, state['baseline_image'], enable=True)
        state['maintenance_owned'] = True
        checkpoint(directory, state)
        runner.compose(project.path, 'stop', '--timeout', '60', *running)
        state['backup'] = database_backup(project.path, directory, state, runner)
        checkpoint(directory, state)
        print('Verified private database dump saved; switching the tested code and PHP image', flush=True)
        state['switch_started'] = True
        checkpoint(directory, state)
        install_php_context(project.path, directory)
        managed_override(project.path, state, state['target_image'], state['target']['php_branch'])
        if project.repository:
            state['previous_assets'] = {name: (project.app / name).exists() for name in ASSETS}
            checkpoint(directory, state)
            untracked = directory / 'previous_untracked'
            untracked.mkdir(mode=0o700)
            tracked = set(git(runner, project.app, 'ls-files', '-z').decode().split('\0'))
            for name in ('composer.lock', 'package-lock.json'):
                if name not in tracked and (project.app / name).exists():
                    os.replace(project.app / name, untracked / name)
            git(runner, project.app, 'merge', '--ff-only', '--quiet', state['approved_commit'])
            os.replace(project.app / 'vendor', directory / 'previous_vendor')
            os.replace(app / 'vendor', project.app / 'vendor')
            for index, name in enumerate(ASSETS):
                source, destination = app / name, project.app / name
                if source.exists():
                    previous = directory / f'previous_asset_{index}'
                    if destination.exists():
                        os.replace(destination, previous)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(source, destination)
        else:
            os.replace(project.app, directory / 'previous_app')
            os.replace(app, project.app)
            for relative in runtime_paths(directory / 'previous_app'):
                source, target = directory / 'previous_app' / relative, project.app / relative
                if source.exists() or source.is_symlink():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if target.exists() or target.is_symlink():
                        raise UpgradeError('Candidate unexpectedly contains live runtime data')
                    os.replace(source, target)
        for path in (project.app / 'bootstrap/cache', project.app / 'storage'):
            os.chown(path, 1000, 1000)
        if tree_hash(project.app) != state['source_hash']:
            raise UpgradeError('The applied application differs from the tested source; restoring previous code before migrations')
        # Artisan cannot clear old provider caches if they prevent Artisan booting.
        clear_bootstrap_cache(project.app)
        runner.compose(project.path, 'up', '-d', '--no-build', '--pull', 'never', 'php')
        runner.live(project.path, directory, state['target_image'], ['php', 'artisan', 'package:discover', '--no-interaction'])
        runner.live(project.path, directory, state['target_image'], ['php', 'artisan', 'optimize:clear'])
        state['migration_started'] = True
        checkpoint(directory, state)
        runner.live(project.path, directory, state['target_image'], ['php', 'artisan', 'migrate', '--force', '--no-interaction'], timeout=600)
        database_ready(runner, project.path, directory, state['target_image'])
        runner.compose(project.path, 'exec', '-T', 'nginx', 'nginx', '-t', timeout=15)
        runner.compose(project.path, 'exec', '-T', 'nginx', 'nginx', '-s', 'reload', timeout=15)
        http_ready(runner, project.path, state)
        maintenance(runner, project.path, directory, state['target_image'], enable=False)
        if len(running) > 1:
            runner.compose(project.path, 'up', '-d', '--no-build', '--pull', 'never', *[role for role in running if role != 'php'])
        state['completed_at'] = int(time.time())
        state['deployed_fingerprint'] = Project(state['slug'], runner).fingerprint()
        checkpoint(directory, state, 'completed')
        print(f'Upgrade completed: Laravel {state["resolved"]["laravel"]}, PHP {state["target"]["php"]}. Recovery plan: {directory / "plan.json"}')
    except BaseException:
        checkpoint(directory, state, 'failed')
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        try:
            recover(directory, state, runner, not state.get('migration_started', False), automatic=True)
        except BaseException:
            print(f'Automatic recovery needs attention. Keep maintenance enabled and inspect {directory / "plan.json"}', file=sys.stderr)
        raise


def recover(directory: Path, state: dict, runner: Runner, database_verified: bool, *, automatic: bool = False) -> None:
    project = WWW / state['slug']
    app = project / 'public_html'
    if state['status'] not in ('failed', 'applying', 'completed', 'needs_database_review', 'recovering'):
        raise UpgradeError('This saved plan has no applied change to recover')
    override = project / 'docker-compose.override.yml'
    if override.exists():
        marker = read_json(override).get('x-laraship-upgrade', {})
        if marker.get('id') != state['id'] and not (state['status'] in ('failed', 'applying', 'recovering') and marker.get('id') == state.get('source_override_id')):
            raise UpgradeError('A different upgrade now owns the project; refuse stale recovery')
    elif state['status'] in ('completed', 'needs_database_review'):
        raise UpgradeError('The applied upgrade override is missing; refuse stale recovery')
    check_image(runner, state['baseline_image'])
    if not state.get('maintenance_owned') and state.get('maintenance_attempted'):
        down = app / 'storage/framework/down'
        token_path = directory / 'maintenance-token'
        if down.exists() and token_path.exists() and read_json(down).get('secret') == token_path.read_text():
            state['maintenance_owned'] = True
    if not state.get('maintenance_owned'):
        checkpoint(directory, state, 'recovered')
        return
    if state['status'] == 'completed':
        if Project(state['slug'], runner).fingerprint() != state.get('deployed_fingerprint'):
            raise UpgradeError('The deployed application changed after this upgrade; refuse stale recovery')
        if state.get('backup') and digest(directory / state['backup']['file']) != state['backup']['sha256']:
            raise UpgradeError('The private pre-upgrade database dump changed; refuse recovery')
    checkpoint(directory, state, 'recovering')
    roles = state.get('running_roles', ['php'])
    previous_down = directory / 'previous_app/storage/framework/down'
    if not (app / 'storage/framework/down').exists() and not previous_down.exists():
        maintenance(runner, project, directory, state['target_image'], enable=True)
    runner.compose(project, 'stop', '--timeout', '60', *roles)
    if state.get('switch_started') and not state.get('code_recovered'):
        if state['repository']:
            git(runner, app, 'reset', '--hard', '--quiet', state['source']['commit'])
            previous = directory / 'previous_untracked'
            if previous.exists():
                for path in previous.iterdir():
                    if path.name not in ('composer.lock', 'package-lock.json'):
                        raise UpgradeError('Unexpected saved untracked path')
                    os.replace(path, app / path.name)
            if (directory / 'previous_vendor').exists():
                if (app / 'vendor').exists():
                    os.replace(app / 'vendor', directory / 'failed_vendor')
                os.replace(directory / 'previous_vendor', app / 'vendor')
            for index, name in enumerate(ASSETS):
                previous, current = directory / f'previous_asset_{index}', app / name
                if previous.exists():
                    if current.exists():
                        os.replace(current, directory / f'failed_asset_{index}')
                    current.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(previous, current)
                elif state.get('previous_assets', {}).get(name) is False and current.exists():
                    os.replace(current, directory / f'failed_asset_{index}')
        elif (directory / 'previous_app').exists():
            previous = directory / 'previous_app'
            if app.exists():
                for relative in runtime_paths(app):
                    source, target = app / relative, previous / relative
                    if (source.exists() or source.is_symlink()) and not (target.exists() or target.is_symlink()):
                        target.parent.mkdir(parents=True, exist_ok=True)
                        os.replace(source, target)
                os.replace(app, directory / 'failed_app')
            os.replace(previous, app)
        state['code_recovered'] = True
        checkpoint(directory, state)
    if not (app / 'storage/framework/down').exists():
        maintenance(runner, project, directory, state['baseline_image'], enable=True)
    # The security patch is retained even when restoring older application code.
    if not (project / '.docker/php').exists():
        shutil.copytree(ROOT / 'laravel/.docker/php', project / '.docker/php')
    partial = project / '.docker/php.upgrade-new'
    if partial.exists():
        os.replace(partial, directory / 'partial_php_context')
    managed_override(project, state, state['baseline_image'], state['baseline_branch'])
    if state.get('switch_started'):
        clear_bootstrap_cache(app)
    runner.compose(project, 'up', '-d', '--no-build', '--pull', 'never', 'php')
    runner.live(project, directory, state['baseline_image'], ['php', 'artisan', 'optimize:clear'])
    runner.compose(project, 'exec', '-T', 'nginx', 'nginx', '-t', timeout=15)
    runner.compose(project, 'exec', '-T', 'nginx', 'nginx', '-s', 'reload', timeout=15)
    if state.get('migration_started') and not database_verified:
        checkpoint(directory, state, 'needs_database_review')
        print(f'Previous code and safe PHP restored. Maintenance/workers remain stopped pending database review. Private dump: {directory / state["backup"]["file"]}')
        return
    database_ready(runner, project, directory, state['baseline_image'])
    http_ready(runner, project, state)
    maintenance(runner, project, directory, state['baseline_image'], enable=False)
    if len(roles) > 1:
        runner.compose(project, 'up', '-d', '--no-build', '--pull', 'never', *[role for role in roles if role != 'php'])
    checkpoint(directory, state, 'recovered')
    print('Previous application code and safe PHP restored; database was not overwritten')


def slug_argument(value: str) -> str:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,62}', value) or value.lower() == 'nginxproxy':
        raise argparse.ArgumentTypeError('Invalid or reserved project slug')
    return value


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    result.add_argument('--version', action='version', version='LaraShip upgrade ' + (ROOT / 'VERSION').read_text().strip())
    result.add_argument('--slug', required=True, type=slug_argument)
    result.add_argument('--laravel-version', help='Target X.Y branch or exact stable X.Y.Z; defaults to the latest reviewed branch')
    mode = result.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='Read-only inspection and compatibility plan (default)')
    mode.add_argument('--prepare', action='store_true', help='Prepare and test a private candidate without changing the live application')
    mode.add_argument('--verify', type=Path, metavar='PLAN', help='Verify a manually adjusted private candidate')
    mode.add_argument('--apply', type=Path, metavar='PLAN', help='Apply the exact prepared candidate after backup')
    mode.add_argument('--recover', type=Path, metavar='PLAN', help='Restore previous code and safe PHP; database recovery is separate')
    result.add_argument('--commit', help='Reviewed upstream application commit, required when applying a --repo project')
    result.add_argument('--test-command', help='Candidate test argv parsed with shlex; runs without production environment or network')
    result.add_argument('--health-path', help='Local HTTP readiness path saved during preparation (default /up)')
    result.add_argument('--database-verified', action='store_true', help='Resume a recovered application only after explicit database verification/restoration')
    result.add_argument('--json', action='store_true', help='Print the read-only compatibility plan as JSON')
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    runner = Runner()
    def cancelled(signum, frame):
        raise KeyboardInterrupt
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, cancelled)
    if hasattr(signal, 'SIGHUP'):
        signal.signal(signal.SIGHUP, cancelled)
    try:
        if sys.platform != 'linux' or os.geteuid() != 0:
            raise UpgradeError('Run this command as root on the target Linux Docker server')
        if os.environ.get('DOCKER_HOST', 'unix:///var/run/docker.sock') != 'unix:///var/run/docker.sock' or os.environ.get('DOCKER_CONTEXT'):
            raise UpgradeError('Use the local Docker socket and unset DOCKER_HOST/DOCKER_CONTEXT overrides')
        if any(os.environ.get(key) for key in ('COMPOSE_FILE', 'COMPOSE_PROJECT_NAME', 'COMPOSE_PROFILES', 'COMPOSE_ENV_FILES', 'COMPOSE_DISABLE_ENV_FILE')):
            raise UpgradeError('Unset Compose project/profile/environment overrides before upgrading')
        if not re.fullmatch(r'/[A-Za-z0-9/_-]*', args.health_path or '/up'):
            raise UpgradeError('Health path must be an absolute HTTP path without query parameters')
        if args.commit and not args.apply or args.database_verified and not args.recover:
            raise UpgradeError('--commit belongs to --apply; --database-verified belongs to --recover')
        if args.laravel_version and (args.apply or args.recover or args.verify):
            raise UpgradeError('Choose a Laravel target when planning/preparing a new candidate')
        if args.test_command and not (args.prepare or args.verify):
            raise UpgradeError('Test commands belong to candidate preparation/verification')
        if args.health_path and (args.apply or args.recover or args.verify):
            raise UpgradeError('Choose the health path when preparing a new candidate')
        if args.json and (args.prepare or args.verify or args.apply or args.recover):
            raise UpgradeError('--json is for read-only planning')
        runner.docker('info', '--format', '{{.OSType}}', timeout=15)
        if args.apply or args.recover:
            with project_lock(args.slug):
                directory, state = load_state(args.apply or args.recover, args.slug)
                runner.owner = state['id']
                runner.cleanup_owned()
                if args.apply:
                    apply_upgrade(directory, state, runner, args.commit)
                else:
                    recover(directory, state, runner, args.database_verified)
        elif args.prepare or args.verify:
            with project_lock(args.slug):
                project = Project(args.slug, runner)
                if args.prepare:
                    prepare(project, args.laravel_version, args.test_command, args.health_path or '/up')
                else:
                    directory, state = load_state(args.verify, args.slug)
                    runner.owner = state['id']
                    runner.cleanup_owned()
                    if args.test_command:
                        state['test_command'] = shlex.split(args.test_command)
                    verify(project, directory, state)
        else:
            plan = Project(args.slug, runner).plan(args.laravel_version)
            if args.json:
                print(json.dumps(plan, indent=2))
            else:
                print(f'Project: {plan["slug"]}\nLaravel: {plan["source"]["laravel"]} -> {plan["target"]["laravel_constraint"]}'
                      f'\nPHP: {plan["source"]["php"]} -> {plan["target"]["php"]}'
                      f'\nFilament target: {plan["target"]["filament_major"] or "not installed"}'
                      '\nNo project files, images, containers or maintenance state were changed. Use --prepare to build and test a candidate.')
        return 0
    except (UpgradeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'LaraShip upgrade: {error}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('LaraShip upgrade cancelled; inspect the saved plan before retrying', file=sys.stderr)
        return 130
    finally:
        for name in list(runner.names):
            runner.remove_owned(name)


if __name__ == '__main__':
    raise SystemExit(main())
