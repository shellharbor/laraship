"""Bounded local Docker operations for the managed upgrader."""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

from upgrade_model import UpgradeError, write_json


class Runner:
    def __init__(self, owner: str = ''):
        self.owner = owner
        self.counter = 0
        self.active = None
        self.names = set()

    def run(self, arguments: list[str], *, cwd: Path | None = None, data: bytes | None = None,
            timeout: int = 120, check: bool = True, output=None, env: dict | None = None, input_stream=None) -> bytes:
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(arguments, cwd=cwd, stdin=input_stream if input_stream is not None else subprocess.PIPE if data is not None else subprocess.DEVNULL,
                stdout=output if output is not None else out, stderr=errors,
                start_new_session=os.name == 'posix', env=env)
            self.active = process
            try:
                process.communicate(input=data, timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                if os.name == 'posix':
                    os.killpg(process.pid, signal.SIGTERM)
                else:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if os.name == 'posix':
                        os.killpg(process.pid, signal.SIGKILL)
                    else:
                        process.kill()
                    process.wait()
                raise UpgradeError('Operation timed out or was cancelled; inspect the saved upgrade state')
            finally:
                self.active = None
            out.seek(0)
            value = out.read(1024 * 1024 + 1)
            if len(value) > 1024 * 1024:
                raise UpgradeError('Operation produced unexpectedly large inspection output')
            if check and process.returncode:
                errors.seek(0)
                # Never echo arbitrary application output or credential-bearing URLs.
                diagnostic = errors.read(1024 * 1024).decode('utf-8', errors='replace') + value.decode('utf-8', errors='replace')
                names = sorted(set(re.findall(r'(?<![/\w.-])([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*)', diagnostic)))
                known = {'laravel/framework', 'laravel/tinker', 'laravel/boost', 'filament/filament', 'filament/upgrade',
                         'livewire/livewire', 'phpunit/phpunit', 'pestphp/pest', 'pestphp/pest-plugin-laravel'}
                packages = [name for name in names if name in known]
                suffix = '; related packages: ' + ', '.join(packages[:8]) if packages else ''
                tool = Path(arguments[0]).name
                context = tool if tool in ('git', 'docker', 'php', 'composer', 'npm') else 'operation'
                raise UpgradeError(f'{context.capitalize()} failed with exit code {process.returncode}{suffix}')
            return value

    def docker(self, *arguments: str, **options) -> bytes:
        return self.run(['docker', '--host', 'unix:///var/run/docker.sock', *arguments], **options)

    def inspect(self, kind: str, identifier: str) -> dict:
        return json.loads(self.docker(kind, 'inspect', identifier))[0]

    def compose(self, project: Path, *arguments: str, extra: Path | None = None, **options) -> bytes:
        command = ['compose', '--project-name', project.name.lower(), '--project-directory', str(project),
                   '--env-file', str(project / '.env'), '-f', str(project / 'docker-compose.yml')]
        override = project / 'docker-compose.override.yml'
        if override.exists():
            command += ['-f', str(override)]
        if extra is not None:
            command += ['-f', str(extra)]
        return self.docker(*command, *arguments, **options)

    def name(self) -> str:
        self.counter += 1
        name = f'laraship-upgrade-{self.owner}-{self.counter}'
        self.names.add(name)
        return name

    def remove_owned(self, name: str) -> None:
        try:
            container = self.inspect('container', name)
            labels = container.get('Config', {}).get('Labels', {})
            if labels.get('io.laraship.upgrade') == self.owner and labels.get('io.laraship.upgrade.role') == 'command':
                self.docker('rm', '--force', container['Id'], check=False)
        except (UpgradeError, json.JSONDecodeError):
            pass
        self.names.discard(name)

    def cleanup_owned(self) -> None:
        if not re.fullmatch(r'[a-f0-9]{32}', self.owner):
            raise UpgradeError('Interrupted-container cleanup requires a saved upgrade identity')
        arguments = ('ps', '--all', '--quiet', '--filter', f'label=io.laraship.upgrade={self.owner}',
                     '--filter', 'label=io.laraship.upgrade.role=command')
        for identifier in self.docker(*arguments).decode().split():
            if not re.fullmatch(r'[a-f0-9]{12,64}', identifier):
                raise UpgradeError('Docker returned an invalid interrupted-container identity')
            self.remove_owned(identifier)
        if self.docker(*arguments).strip():
            raise UpgradeError('Interrupted upgrade containers could not be removed; recovery is stopped')

    def candidate(self, app: Path, image: str, arguments: list[str], *, network: bool = False,
                  environment: dict | None = None, timeout: int = 600, data: bytes | None = None) -> bytes:
        name = self.name()
        settings = {'APP_ENV': 'testing', 'APP_DEBUG': 'false', 'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                    'APP_URL': 'http://localhost', 'DB_CONNECTION': 'sqlite', 'DB_DATABASE': ':memory:',
                    'CACHE_STORE': 'array', 'CACHE_DRIVER': 'array', 'SESSION_DRIVER': 'array',
                    'QUEUE_CONNECTION': 'sync', 'MAIL_MAILER': 'log', 'LOG_CHANNEL': 'stderr',
                    'APP_MAINTENANCE_DRIVER': 'file', 'COMPOSER_HOME': '/tmp/composer',
                    'COMPOSER_CACHE_DIR': '/tmp/composer-cache', 'HOME': '/tmp', 'NPM_CONFIG_CACHE': '/tmp/npm-cache'}
        settings.update(environment or {})
        command = ['run', '--rm', '--name', name, '--label', f'io.laraship.upgrade={self.owner}',
                   '--label', 'io.laraship.upgrade.role=command',
                   '--log-driver', 'none',
                   '--network', 'bridge' if network else 'none', '--read-only', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges', '--user', '1000:1000', '--workdir', '/var/www/html',
                   '--memory', '1g', '--cpus', '2', '--pids-limit', '256',
                   '--tmpfs', '/tmp:rw,exec,uid=1000,gid=1000,size=256m',
                   '--mount', f'type=bind,src={app},dst=/var/www/html']
        for key, value in settings.items():
            # Candidate settings are synthetic or explicitly public VITE_ build values.
            command += ['--env', f'{key}={value}']
        if data is not None:
            command.append('--interactive')
        command += ['--entrypoint', arguments[0], image, *arguments[1:]]
        try:
            return self.docker(*command, data=data, timeout=timeout)
        finally:
            self.remove_owned(name)

    def live(self, project: Path, state_dir: Path, image: str, arguments: list[str], *, timeout: int = 120,
             data: bytes | None = None, environment: dict | None = None) -> bytes:
        override = state_dir / 'cli-runtime.json'
        service = {'image': image, 'pull_policy': 'never', 'logging': {'driver': 'none'}}
        if environment:
            service['environment'] = environment
        write_json(override, {'services': {'php': service}})
        name = self.name()
        try:
            return self.compose(project, 'run', '--rm', '--no-deps', '-T', '--name', name,
                '--label', f'io.laraship.upgrade={self.owner}', '--label', 'io.laraship.upgrade.role=command',
                '--entrypoint', arguments[0], 'php',
                *arguments[1:], extra=override, timeout=timeout, data=data)
        finally:
            self.remove_owned(name)

    def build(self, root: Path, branch: str, tag: str, state_dir: Path) -> str:
        iid = state_dir / (branch.replace('.', '') + '.iid')
        self.docker('build', '--iidfile', str(iid), '--label', f'io.laraship.upgrade.image={self.owner}',
            '--tag', tag, '--file', str(root / f'laravel/.docker/php/php{branch.replace(".", "")}.Dockerfile'),
            str(root / 'laravel/.docker/php'), timeout=1800)
        identifier = iid.read_text(encoding='ascii').strip()
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', identifier):
            raise UpgradeError('Builder did not return an immutable image ID')
        return identifier


@contextmanager
def project_lock(slug: str, directory: Path = Path('/run/lock/laraship')):
    import fcntl
    if directory.is_symlink():
        raise UpgradeError('Refusing a symbolic link lock directory')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.stat().st_uid != os.geteuid():
        raise UpgradeError('Lock directory has an unexpected owner')
    directory.chmod(0o700)
    path = directory / f'project-{slug}.lock'
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + 60
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise UpgradeError('Another operation holds the project lock')
                time.sleep(0.1)
        yield
    finally:
        os.close(descriptor)
