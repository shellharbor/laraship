#!/usr/bin/env python3
"""Real managed upgrades on an explicitly disposable Linux Docker server."""
import argparse
import base64
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import upgrade as engine
from upgrade_model import digest, read_json, tree_hash, write_json
from upgrade_runtime import Runner


class Fixture:
    def __init__(self, db, source_php, filament, repository, cli_image=None):
        self.runner = Runner(uuid.uuid4().hex)
        self.slug = 'upgrade-' + self.runner.owner[:10]
        self.path = Path('/var/www') / self.slug
        if self.path.exists():
            raise RuntimeError('Fixture path collision')
        self.app = self.path / 'public_html'
        self.db, self.source_php, self.filament, self.repository = db, source_php, filament, repository
        self.cli_image = cli_image
        self.image = 'laraship-php:upgrade-' + source_php
        self.upstream = self.path / 'upstream'

    def command(self, *arguments, check=True):
        environment = dict(os.environ, PYTHONPATH=str(ROOT / 'src'))
        command = ([sys.executable, '-B', '-m', 'laraship', 'upgrade', '--backend', 'docker', '--image', self.cli_image, '--']
                   if self.cli_image else ['bash', str(ROOT / 'upgrade.sh')])
        result = subprocess.run([*command, '--slug', self.slug, *arguments], env=environment,
                                capture_output=True, text=True, timeout=2400)
        # Fixtures use synthetic credentials, but do not print backend argument lists.
        if check and result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result

    def artisan(self, *args):
        return self.runner.compose(self.path, 'run', '--rm', '--no-deps', '-T', 'artisan', *args, timeout=600)

    def git(self, path, *args):
        return self.runner.run(['git', '-c', f'safe.directory={path}', '-c', 'user.name=Upgrade Fixture',
            '-c', 'user.email=upgrade@example.test', '-C', str(path), *args]).decode().strip()

    def wait_http(self, expected=200):
        for _ in range(40):
            try:
                with urlopen(Request('http://127.0.0.1:18880/upgrade-probe', headers={'Host': self.slug + '.example.test'}), timeout=3) as result:
                    if result.status == expected:
                        return
            except HTTPError as error:
                if error.code == expected:
                    return
            except (URLError, TimeoutError):
                pass
            time.sleep(1)
        raise RuntimeError(f'Fixture HTTP readiness did not return {expected}')

    def require_running_roles(self, image):
        for role in ('php', 'cron', 'queue'):
            identifier = self.runner.compose(self.path, 'ps', '--status', 'running', '-q', role).decode().strip()
            if not identifier:
                raise RuntimeError(f'Fixture PHP role {role} is not running')
            if self.runner.inspect('container', identifier)['Image'] != image:
                raise RuntimeError(f'Fixture PHP role {role} is using an unexpected image')

    def create(self):
        self.path.mkdir(parents=True)
        shutil.copytree(ROOT / 'laravel/.docker/php', self.path / '.docker/php')
        self.app.mkdir()
        os.chown(self.app, 1000, 1000)
        print('Creating the real Laravel 12 source and database fixture', flush=True)
        self.runner.candidate(self.app, self.image, ['composer', 'create-project', 'laravel/laravel', '.', '^12.0',
            '--no-scripts', '--no-interaction', '--prefer-dist', '--no-progress'], network=True, timeout=900)
        # create-project's example file is never a real environment or source secret.
        for path in self.app.glob('.env*'):
            path.unlink()
        with (self.app / 'routes/web.php').open('a') as stream:
            stream.write("\nRoute::get('/upgrade-probe', fn () => (string) \\Illuminate\\Support\\Facades\\DB::table('upgrade_probe')->where('id', 1)->value('value'));\n")
        (self.app / 'app/Jobs').mkdir(exist_ok=True)
        (self.app / 'app/Jobs/UpgradeProbe.php').write_text('''<?php
namespace App\\Jobs;
use Illuminate\\Contracts\\Queue\\ShouldQueue;
use Illuminate\\Support\\Facades\\DB;
final class UpgradeProbe implements ShouldQueue
{
    public function handle(): void
    {
        DB::table('upgrade_probe')->updateOrInsert(['id' => 2], ['value' => 'queued']);
    }
}
''')
        if self.filament:
            self.runner.candidate(self.app, self.image, ['composer', 'require', f'filament/filament:^{self.filament}.0',
                '--no-scripts', '--no-interaction', '--no-progress'], network=True, timeout=900)
            self.runner.candidate(self.app, self.image, ['php', 'artisan', 'package:discover'])
            self.runner.candidate(self.app, self.image, ['php', 'artisan', 'filament:install', '--panels', '--no-interaction'])
        self.password = 'Upgrade_Fake_Only1'
        env = ('APP_NAME=UpgradeFixture\nAPP_ENV=production\nAPP_DEBUG=false\n'
               'APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
               f'APP_URL=http://{self.slug}.example.test\nDB_CONNECTION={"pgsql" if self.db == "postgres" else "mysql"}\n'
               f'DB_HOST=db\nDB_PORT={5432 if self.db == "postgres" else 3306}\nDB_DATABASE=upgrade\nDB_USERNAME=upgrade\n'
               f'DB_PASSWORD={self.password}\nCACHE_STORE=file\nSESSION_DRIVER=file\nQUEUE_CONNECTION=database\n'
               'APP_MAINTENANCE_DRIVER=file\nLOG_CHANNEL=stderr\n')
        (self.app / '.env').write_text(env)
        (self.app / '.env').chmod(0o600)
        (self.path / '.env').write_text(f'SITE_HOST={self.slug}.example.test\nSITE_PORT_HTTP=18880\nDB_NATIVE=false\n')
        (self.path / '.env').chmod(0o600)
        (self.app / 'storage/app/upload.txt').write_text('persistent synthetic upload')
        engine.own(self.app)
        role = {'image': self.image, 'build': {'context': './.docker/php', 'dockerfile': f'php{self.source_php}.Dockerfile'},
                'volumes': ['./public_html:/var/www/html'], 'stop_grace_period': '15s'}
        services = {name: dict(role) for name in ('php', 'artisan', 'composer', 'cron', 'queue')}
        services['php']['container_name'] = self.slug + '_php'
        services['artisan'].update(entrypoint=['php', 'artisan'])
        services['composer'].update(entrypoint=['composer'])
        services['cron']['command'] = ['php', 'artisan', 'schedule:work']
        services['queue']['command'] = ['php', 'artisan', 'queue:work', '--sleep=1']
        if self.db == 'postgres':
            services['db'] = {'image': 'postgres:17', 'environment': {'POSTGRES_USER': 'upgrade',
                'POSTGRES_PASSWORD': self.password, 'POSTGRES_DB': 'upgrade'}, 'volumes': ['database:/var/lib/postgresql/data']}
        else:
            services['db'] = {'image': 'mysql:8.4', 'environment': {'MYSQL_USER': 'upgrade', 'MYSQL_PASSWORD': self.password,
                'MYSQL_DATABASE': 'upgrade', 'MYSQL_ROOT_PASSWORD': 'Root_Fake_Only1'}, 'volumes': ['database:/var/lib/mysql']}
        nginx = self.path / 'nginx.conf'
        nginx.write_text('server { listen 80; server_name _; root /var/www/html/public; index index.php;\n'
            'location / { try_files $uri $uri/ /index.php?$query_string; }\n'
            'location ~ \\.php$ { include fastcgi_params; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; '
            f'fastcgi_pass {self.slug}_php:9000; }} }}\n')
        services['nginx'] = {'image': 'nginx:1.29.1-alpine', 'ports': ['127.0.0.1:18880:80'],
            'volumes': ['./public_html:/var/www/html', './nginx.conf:/etc/nginx/conf.d/default.conf:ro']}
        write_json(self.path / 'docker-compose.yml', {'services': services, 'volumes': {'database': {}}})
        # A database-backed queue exits if MySQL or its jobs table is not ready.
        # Such a stopped worker must remain stopped by the upgrader, so start it
        # only after this fixture has initialized and seeded the database.
        self.runner.compose(self.path, 'up', '-d', '--no-build', 'db', 'php', 'nginx', timeout=300)
        for attempt in range(60):
            try:
                self.artisan('migrate', '--force', '--no-interaction')
                break
            except engine.UpgradeError:
                if attempt == 59:
                    raise
                time.sleep(2)
        self.runner.compose(self.path, 'exec', '-T', 'php', 'php', '-r',
            "require 'vendor/autoload.php'; $app=require 'bootstrap/app.php'; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); "
            "Illuminate\\Support\\Facades\\DB::statement('CREATE TABLE upgrade_probe (id INTEGER PRIMARY KEY, value TEXT)'); "
            "Illuminate\\Support\\Facades\\DB::table('upgrade_probe')->insert([['id'=>1,'value'=>'retained'], "
            "['id'=>3,'value'=>Illuminate\\Support\\Facades\\Crypt::encryptString('synthetic encrypted data')]]);")
        if self.repository:
            self.upstream.mkdir()
            self.git(self.upstream, 'init', '--quiet', '--initial-branch=main')
            # Use an actual upstream without dependencies, secrets or generated frontend.
            source_files = engine.files(self.app) + [path.relative_to(self.app) for path in (self.app / 'storage').rglob('.gitignore')]
            for relative in source_files:
                target = self.upstream / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(self.app / relative, target)
            self.git(self.upstream, 'add', '--all')
            self.git(self.upstream, 'add', '--force', 'composer.lock')
            self.git(self.upstream, 'commit', '--quiet', '-m', 'Original fixture application')
            self.git(self.app, 'init', '--quiet', '--initial-branch=main')
            self.git(self.app, 'remote', 'add', 'origin', str(self.upstream))
            self.git(self.app, 'fetch', '--quiet', 'origin')
            self.git(self.app, 'reset', '--mixed', 'origin/main')
            (self.path / '.deploy-meta').write_text('REPO_BRANCH=main\n')
        self.runner.compose(self.path, 'up', '-d', '--no-build', 'cron', 'queue', timeout=120)
        self.require_running_roles(self.runner.inspect('image', self.image)['Id'])
        self.wait_http()

    def retained(self):
        self.wait_http()
        assert (self.app / '.env').read_text() == self.original_env
        assert (self.app / 'storage/app/upload.txt').read_text() == 'persistent synthetic upload'
        result = self.runner.compose(self.path, 'exec', '-T', 'php', 'php', '-r',
            "require 'vendor/autoload.php'; $app=require 'bootstrap/app.php'; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); "
            "echo json_encode(['value'=>Illuminate\\Support\\Facades\\DB::table('upgrade_probe')->where('id',1)->value('value'), "
            "'decrypted'=>Illuminate\\Support\\Facades\\Crypt::decryptString(Illuminate\\Support\\Facades\\DB::table('upgrade_probe')->where('id',3)->value('value'))]);")
        assert json.loads(result) == {'value': 'retained', 'decrypted': 'synthetic encrypted data'}

    def queue_probe(self, *, dispatch=False):
        if dispatch:
            self.runner.compose(self.path, 'exec', '-T', 'php', 'php', '-r',
                "require 'vendor/autoload.php'; $app=require 'bootstrap/app.php'; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); "
                "Illuminate\\Support\\Facades\\Bus::dispatch(new App\\Jobs\\UpgradeProbe);")
        for _ in range(30):
            result = self.runner.compose(self.path, 'exec', '-T', 'php', 'php', '-r',
                "require 'vendor/autoload.php'; $app=require 'bootstrap/app.php'; $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap(); "
                "echo Illuminate\\Support\\Facades\\DB::table('upgrade_probe')->where('id',2)->value('value');")
            if result == b'queued':
                return
            time.sleep(1)
        raise RuntimeError('The upgraded worker did not process its database-backed job')

    def configuration_guard(self):
        directory = self.path / '.configuration-probe'
        directory.mkdir(mode=0o700)
        image = self.runner.inspect('image', self.image)['Id']
        environment = self.app / '.env'
        original = environment.read_text()
        pending = 'base64:' + base64.b64encode(b'B' * 32).decode()
        try:
            engine.checked_environment(self.runner, self.path, directory, image)
            self.runner.live(self.path, directory, image, ['php', 'artisan', 'config:cache'])
            changed, count = re.subn(r'^APP_KEY=.*$', 'APP_KEY=' + pending, original, flags=re.M)
            assert count == 1 and changed != original
            environment.write_text(changed)
            try:
                engine.checked_environment(self.runner, self.path, directory, image)
            except engine.UpgradeError as error:
                assert 'encryption settings differ' in str(error)
                assert pending not in str(error)
            else:
                raise AssertionError('A pending encryption key change was accepted')
        finally:
            environment.write_text(original)
            self.runner.live(self.path, directory, image, ['php', 'artisan', 'config:clear'])
            shutil.rmtree(directory)
        print('PASS: cached encryption-key drift refused without changing live environment files', flush=True)

    def run(self):
        self.create()
        self.configuration_guard()
        self.original_env = (self.app / '.env').read_text()
        original_assets = {name: tree_hash(self.app / name, source=False) if (self.app / name).exists() else None for name in engine.ASSETS}
        before = tree_hash(self.app, source=False)
        containers = self.runner.docker('ps', '-q')
        plan = json.loads(self.command('--json').stdout)
        assert plan['target']['laravel_major'] == 13
        assert plan['target']['php'] == '8.3.36'
        assert not (self.path / '.laraship-upgrades').exists()
        assert tree_hash(self.app, source=False) == before
        assert self.runner.docker('ps', '-q') == containers
        print('PASS: planning did not change source, dependencies, containers or maintenance', flush=True)
        result = self.command('--prepare', '--health-path', '/upgrade-probe')
        print(result.stdout, end='', flush=True)
        saved = list((self.path / '.laraship-upgrades').glob('*/plan.json'))
        assert len(saved) == 1
        directory, state = saved[0].parent, read_json(saved[0])
        assert state['status'] == 'prepared'
        assert not any((directory / 'candidate').glob('.env*'))
        assert (directory / 'application.patch').stat().st_mode & 0o077 == 0
        self.retained()
        candidate = directory / 'candidate'
        prepared_assets = {name: tree_hash(candidate / name, source=False) if (candidate / name).exists() else None for name in engine.ASSETS}
        original = (candidate / 'composer.json').read_bytes()
        (candidate / 'composer.json').write_bytes(original + b'\n')
        assert self.command('--apply', str(saved[0]), check=False).returncode != 0
        assert not (self.app / 'storage/framework/down').exists()
        (candidate / 'composer.json').write_bytes(original)
        arguments = ['--apply', str(saved[0])]
        if self.repository:
            patchfile = (directory / 'application.patch').read_bytes()
            self.runner.run(['git', '-C', str(self.upstream), 'apply', '--index', '--binary', '-'], data=patchfile)
            self.git(self.upstream, 'commit', '--quiet', '-m', 'Reviewed application upgrade')
            arguments += ['--commit', self.git(self.upstream, 'rev-parse', 'HEAD')]
        result = self.command(*arguments)
        print(result.stdout, end='', flush=True)
        state = read_json(saved[0])
        assert state['status'] == 'completed'
        assert state['backup']['sha256'] == digest(directory / state['backup']['file'])
        assert state['resolved']['laravel'].lstrip('v').startswith('13.')
        if self.filament:
            assert state['resolved']['filament'].lstrip('v').startswith('5.')
        config = json.loads(self.runner.compose(self.path, 'config', '--format', 'json'))
        for role in state['roles']:
            assert config['services'][role]['image'] == state['target_image']
        assert state['running_roles'] == ['php', 'cron', 'queue'], 'Fixture roles stopped before apply'
        self.require_running_roles(state['target_image'])
        for name, value in prepared_assets.items():
            assert (tree_hash(self.app / name, source=False) if (self.app / name).exists() else None) == value
        self.retained()
        self.queue_probe(dispatch=True)
        print('PASS: versions, database dump, HTTP, application key, uploaded data and PHP roles survived apply', flush=True)
        # A successful apply can restore code, but needs explicit schema review to resume.
        print(self.command('--recover', str(saved[0])).stdout, end='', flush=True)
        assert read_json(saved[0])['status'] == 'needs_database_review'
        self.wait_http(503)
        print(self.command('--recover', str(saved[0]), '--database-verified').stdout, end='', flush=True)
        assert read_json(saved[0])['status'] == 'recovered'
        self.retained()
        self.queue_probe()
        assert engine.packages(read_json(self.app / 'composer.lock'))['laravel/framework'].lstrip('v').startswith('12.')
        for name, value in original_assets.items():
            assert (tree_hash(self.app / name, source=False) if (self.app / name).exists() else None) == value
        print('PASS: explicit code recovery retained the patched PHP runtime and never overwrote the database', flush=True)

    def cleanup(self):
        for name in list(self.runner.names):
            self.runner.remove_owned(name)
        if (self.path / 'docker-compose.yml').exists():
            self.runner.compose(self.path, 'down', '--volumes', '--remove-orphans', check=False, timeout=120)
        # Only the nonce-owned fixture created by this object is eligible.
        if self.path.name == self.slug and self.path.parent == Path('/var/www'):
            shutil.rmtree(self.path, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', choices=('postgres', 'mysql'), default='postgres')
    parser.add_argument('--source-php', choices=('82', '83'), default='82')
    parser.add_argument('--filament', choices=(4, 5), type=int)
    parser.add_argument('--repository', action='store_true')
    parser.add_argument('--cli-image', help='Exercise the actual Python Docker adapter using this locally built image')
    args = parser.parse_args()
    if os.environ.get('E2E_ALLOW') != '1' or sys.platform != 'linux' or os.geteuid() != 0:
        raise SystemExit('Use E2E_ALLOW=1 only on a disposable root Linux Docker server')
    fixture = Fixture(args.db, args.source_php, args.filament, args.repository, args.cli_image)
    try:
        fixture.run()
    except BaseException:
        if os.environ.get('E2E_KEEP_FAILED') == '1':
            print(f'Explicitly retained failed disposable fixture: {fixture.path}', flush=True)
            raise
        fixture.cleanup()
        raise
    else:
        fixture.cleanup()


if __name__ == '__main__':
    main()
