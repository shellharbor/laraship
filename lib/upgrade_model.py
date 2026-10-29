"""Pure upgrade policy, safe source snapshots and sealed artifact primitives."""
from __future__ import annotations

from datetime import date
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from urllib.parse import urlsplit


class UpgradeError(Exception):
    """An unsupported or unsafe upgrade, with a public diagnostic only."""


ASSETS = ('public/build', 'public/css/filament', 'public/js/filament', 'public/fonts/filament')


def version(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r'v?(\d+)\.(\d+)(?:\.(\d+))?', value)
    if not match:
        raise UpgradeError('Use a stable version in X.Y or X.Y.Z format')
    return tuple(int(part or 0) for part in match.groups())


def read_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise UpgradeError(f'Expected a regular bounded JSON file: {path.name}')
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        raise UpgradeError(f'Expected a JSON object: {path.name}')
    return data


def write_json(path: Path, value: dict) -> None:
    descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as output:
            json.dump(value, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        if os.name == 'posix':
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def excluded(relative: Path) -> bool:
    parts = relative.parts
    return (parts[0] in ('.git', 'vendor', 'node_modules', 'storage', '.phpunit.cache', '.phpunit.result.cache', 'coverage')
            or any(part.startswith('.env') or part in ('.git', 'auth.json', '.npmrc')
                   or part.endswith(('.pem', '.key', '.p12', '.pfx')) or part.startswith(('id_rsa', 'id_ed25519')) for part in parts)
            or parts[:2] in (('public', 'storage'), ('public', 'hot'), ('public', 'build'))
            or any(relative == Path(asset) or Path(asset) in relative.parents for asset in ASSETS)
            or parts[:2] == ('bootstrap', 'cache') and relative.suffix == '.php')


def files(root: Path, *, source: bool = True) -> list[Path]:
    result = []
    for parent, directories, names in os.walk(root, followlinks=False):
        parent_path = Path(parent)
        for name in list(directories):
            path = parent_path / name
            relative = path.relative_to(root)
            if source and excluded(relative):
                directories.remove(name)
            elif path.is_symlink():
                directories.remove(name)
                result.append(relative)
        for name in names:
            relative = (parent_path / name).relative_to(root)
            if not source or not excluded(relative):
                result.append(relative)
    return sorted(result)


def tree_hash(root: Path, *, source: bool = True) -> str:
    value = hashlib.sha256()
    for relative in files(root, source=source):
        path = root / relative
        value.update(relative.as_posix().encode('utf-8') + b'\0')
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
                raise UpgradeError('Source symlinks must stay inside the application')
            value.update(b'link\0' + target.encode('utf-8'))
        elif stat.S_ISREG(mode):
            value.update(bytes([bool(mode & stat.S_IXUSR)]))
            value.update(digest(path).encode('ascii'))
        else:
            raise UpgradeError('Special files are unsupported in application source')
    return value.hexdigest()


def copy_source(source: Path, target: Path) -> None:
    tree_hash(source)  # Validate links/types before creating any output.
    target.mkdir(mode=0o755)
    for relative in files(source):
        src, dst = source / relative, target / relative
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)


def discard(path: Path, boundary: Path) -> None:
    if path == boundary or not path.absolute().is_relative_to(boundary.absolute()):
        raise UpgradeError('Refusing cleanup outside its private workspace')
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        if not path.resolve().is_relative_to(boundary.resolve()):
            raise UpgradeError('Refusing cleanup through a symbolic link')
        shutil.rmtree(path) if path.is_dir() else path.unlink()


def packages(lock: dict) -> dict[str, str]:
    result = {}
    for package in lock.get('packages', []):
        if isinstance(package, dict) and isinstance(package.get('name'), str) and isinstance(package.get('version'), str):
            result[package['name']] = package['version']
    if 'laravel/framework' not in result:
        raise UpgradeError('composer.lock must contain laravel/framework in production dependencies')
    return result


def validate_composer(config: dict) -> None:
    if not isinstance(config.get('require'), dict) or 'laravel/framework' not in config['require']:
        raise UpgradeError('The application must directly require laravel/framework')
    settings = config.get('config', {})
    if not isinstance(settings, dict) or not isinstance(settings.get('audit', {}), dict) or not isinstance(settings.get('policy', {}), dict):
        raise UpgradeError('Composer settings must be JSON objects')
    if settings.get('vendor-dir', 'vendor') != 'vendor':
        raise UpgradeError('Custom vendor directories are unsupported')
    audit = settings.get('audit', {})
    advisories = settings.get('policy', {}).get('advisories', {})
    if (audit.get('block-insecure') is False or advisories is False
            or isinstance(advisories, dict) and advisories.get('block') is False):
        raise UpgradeError('Enable Composer advisory blocking before preparing an upgrade')
    if any(audit.get(key) for key in ('ignore', 'ignore-severity', 'ignore-unreachable')) or (
            isinstance(advisories, dict) and any(advisories.get(key) for key in ('ignore', 'ignore-id', 'ignore-severity'))):
        raise UpgradeError('Remove advisory exceptions before preparing an upgrade')
    if any(settings.get(key) for key in ('github-oauth', 'gitlab-oauth', 'gitlab-token', 'http-basic', 'bearer', 'custom-headers')):
        raise UpgradeError('Composer credentials must not be embedded in the candidate manifest')
    if settings.get('disable-tls') or settings.get('secure-http') is False:
        raise UpgradeError('Composer dependency downloads must retain verified HTTPS')
    platform = settings.get('platform', {})
    if platform:
        raise UpgradeError('Remove Composer platform overrides; upgrades resolve against the actual target runtime')
    for repository in config.get('repositories', [] if isinstance(config.get('repositories', []), list) else {}):
        item = repository if isinstance(repository, dict) else config['repositories'][repository]
        if isinstance(item, dict):
            if item.get('type') == 'path':
                raise UpgradeError('Path repositories need an application-specific upgrade workflow')
            url = str(item.get('url', ''))
            if urlsplit(url).username or urlsplit(url).password or '?' in url:
                raise UpgradeError('Repository credentials/query tokens must not appear in composer.json URLs')


def choose(root: Path, current: dict[str, str], php: str, requested: str | None,
           minimum: str = '12.0', today: date | None = None) -> dict:
    policy = read_json(root / 'lib/upgrade-policy.json')
    today = today or date.today()
    source = version(current['laravel/framework'])
    target_text = requested or policy['latest_laravel']
    target = version(target_text)
    if source[0] not in (12, 13):
        raise UpgradeError('This upgrader supports Laravel 12/13 sources and the 12 to 13 path only')
    if target < max((12, 0, 0), version(minimum)) or str(target[0]) not in policy['laravel']:
        raise UpgradeError('Target Laravel must satisfy the configured minimum and reviewed Laravel 12/13 matrix')
    if target[0] < source[0] or target[0] == source[0] and (target[1] < source[1] and target[1] != 0
            or target_text.count('.') == 2 and target < source):
        raise UpgradeError('Laravel downgrades are forbidden')
    rule = policy['laravel'][str(target[0])]
    if today > date.fromisoformat(rule['security_until']):
        raise UpgradeError('The target Laravel branch no longer has security support; update the target/toolkit')
    branch = '.'.join(str(part) for part in version(php)[:2])
    if branch not in policy['php_templates']:
        raise UpgradeError('This release builds reviewed PHP 8.2/8.3 templates only; custom branches need a reviewed workflow')
    target_branch = branch if branch in rule['php'] else rule['php'][0]
    template = root / 'laravel/.docker/php' / policy['php_templates'][target_branch]
    match = re.search(r'^FROM php:(\d+\.\d+\.\d+)-fpm-\S+@sha256:[a-f0-9]{64}', template.read_text(encoding='utf-8'), re.M)
    if not match or version(match[1]) < version(php):
        raise UpgradeError('The bundled PHP template would downgrade the runtime; update the toolkit first')
    filament = current.get('filament/filament')
    if not filament and any(name.startswith('filament/') for name in current):
        raise UpgradeError('Filament component-only applications need a reviewed application-specific migration')
    if filament and version(filament)[0] not in policy['filament']['upgrade_from']:
        raise UpgradeError('Filament 4/5 sources are supported; earlier major upgrades require a separate reviewed migration')
    return {'laravel_constraint': target_text if target_text.count('.') == 2 else '^' + target_text,
            'laravel_major': target[0], 'php': match[1], 'php_branch': target_branch,
            'filament_major': policy['filament']['target_major'] if filament else None,
            'filament_upgrade': bool(filament and version(filament)[0] == 4),
            'node_image': policy['node_image'], 'reviewed_at': policy['reviewed_at']}


def recipe(config: dict, target: dict) -> dict:
    result = json.loads(json.dumps(config))
    result['require']['php'] = '^' + target['php']
    result['require']['laravel/framework'] = target['laravel_constraint']
    if target['laravel_major'] == 13:
        for section, updates in [('require', {'laravel/tinker': '^3.0', 'laravel/boost': '^2.0'}),
            ('require-dev', {'phpunit/phpunit': '^12.0', 'pestphp/pest': '^4.0', 'pestphp/pest-plugin-laravel': '^4.0'})]:
            for package, constraint in updates.items():
                if package in result.get(section, {}):
                    result[section][package] = constraint
    for section in ('require', 'require-dev'):
        for package in result.get(section, {}):
            if package == 'livewire/livewire' and target['filament_major']:
                result[section][package] = '^4.0'
            elif package.startswith('filament/') and target['filament_major']:
                result[section][package] = '^5.0'
    if target['filament_upgrade']:
        result.setdefault('require-dev', {})['filament/upgrade'] = '^5.0'
    return result
