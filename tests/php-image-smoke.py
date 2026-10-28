#!/usr/bin/env python3
"""Exercise built PHP runtimes with private Docker resources and real dependencies."""
import argparse
import concurrent.futures
import json
import os
import re
import signal
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PHP_FIXTURE = '''<?php
if (isset($_GET['slow'])) {
    file_put_contents('/tmp/laraship-request-active', 'yes');
    sleep(2);
    echo 'drained';
    exit;
}
$results = [];
foreach (['pgsql', 'mysql'] as $driver) {
    $db = new PDO(getenv(strtoupper($driver) . '_DSN'), 'smoke', 'Smoke_Fake_Only1',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 2]);
    $db->exec('CREATE TABLE IF NOT EXISTS runtime_smoke (id INTEGER PRIMARY KEY, value VARCHAR(100))');
    $db->exec('DELETE FROM runtime_smoke');
    $query = $db->prepare('INSERT INTO runtime_smoke (id, value) VALUES (?, ?)');
    $query->execute([1, "quote' and unicode caf\u00e9"]);
    $results[$driver] = $db->query('SELECT value FROM runtime_smoke WHERE id = 1')->fetchColumn();
}
header('Content-Type: application/json');
echo json_encode(['uid' => posix_geteuid(), 'databases' => $results]);
'''


class Smoke:
    def __init__(self, image: str, variant: str):
        self.image, self.variant = image, variant
        self.owner = uuid.uuid4().hex
        self.containers: list[str] = []
        self.network = self.volume = None
        self.client = ['docker']
        if os.environ.get('LARASHIP_DOCKER_CONFIG'):
            self.client += ['--config', os.environ['LARASHIP_DOCKER_CONFIG']]

    def docker(self, *args: str, input_text: str | None = None, timeout: int = 120,
               check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run([*self.client, *args], input=input_text, text=True, encoding='utf-8',
                                capture_output=True, timeout=timeout, check=False)
        if check and result.returncode:
            raise RuntimeError(f'Docker operation {args[0]} failed: {(result.stderr + result.stdout)[-3000:]}')
        return result

    def create(self, *args: str) -> str:
        identifier = self.docker('create', '--label', f'io.laraship.php-smoke={self.owner}', *args).stdout.strip()
        self.containers.append(identifier)
        return identifier

    def run(self, command: list[str], *, volume: bool = False, env: dict[str, str] | None = None,
            timeout: int = 120, input_text: str | None = None) -> str:
        options = ['--network', self.network, '--read-only', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,uid=1000,gid=1000']
        if volume:
            options += ['--mount', f'type=volume,source={self.volume},target=/var/www/html']
        for key, value in (env or {}).items():
            options += ['--env', f'{key}={value}']
        if input_text is not None:
            options.append('--interactive')
        identifier = self.create(*options, '--entrypoint', command[0], self.image, *command[1:])
        result = self.docker('start', '--attach', *(('--interactive',) if input_text is not None else ()),
                             identifier, input_text=input_text, timeout=timeout)
        exit_code = self.docker('inspect', '--format', '{{.State.ExitCode}}', identifier).stdout.strip()
        if exit_code != '0':
            raise RuntimeError(f'PHP utility failed ({exit_code}): {(result.stderr + result.stdout)[-3000:]}')
        return result.stdout

    def cleanup(self) -> None:
        # IDs came from successful creates; network/volume names contain a private nonce.
        for identifier in reversed(self.containers):
            self.docker('rm', '--force', '--volumes', identifier, check=False)
        if self.volume:
            self.docker('volume', 'rm', self.volume, check=False)
        if self.network:
            self.docker('network', 'rm', self.network, check=False)

    def test(self) -> None:
        dockerfile = (ROOT / f'laravel/.docker/php/php{self.variant}.Dockerfile').read_text(encoding='utf-8')
        builder = (ROOT / 'laravel/.docker/php/build-extensions.sh').read_text(encoding='utf-8')
        php_version = re.search(r'FROM php:(\d+\.\d+\.\d+)-fpm-', dockerfile)[1]
        composer_version = re.search(r'FROM composer:(\d+\.\d+\.\d+)', dockerfile)[1]
        redis_version = re.search(r'^REDIS_VERSION=(.*)$', builder, re.M)[1]
        apcu_version = re.search(r'^APCU_VERSION=(.*)$', builder, re.M)[1]
        image = json.loads(self.docker('image', 'inspect', self.image).stdout)[0]
        assert image['Config']['User'] == '1000:1000'
        assert image['Config']['StopSignal'] == 'SIGQUIT'
        assert image['Config']['Entrypoint'] == ['docker-php-entrypoint']
        self.network = self.docker('network', 'create', f'laraship-php-{self.owner}').stdout.strip()
        self.volume = f'laraship-php-{self.owner}'
        self.docker('volume', 'create', '--label', f'io.laraship.php-smoke={self.owner}', self.volume)
        print(self.run(['php'], input_text=(ROOT / 'tests/security-policy.php').read_text(encoding='utf-8')).strip(), flush=True)
        core = self.run(['php', '-r', '''
            foreach (['mbstring','zip','exif','pcntl','ctype','xml','intl','PDO','mysqli',
                      'pdo_mysql','pgsql','pdo_pgsql','pdo_sqlite','gd','bcmath','sockets','redis','apcu'] as $ext) {
                if (!extension_loaded($ext)) { throw new RuntimeException("Missing extension: $ext"); }
            }
            $info = gd_info();
            foreach (['FreeType Support','JPEG Support','PNG Support','WebP Support'] as $feature) {
                if (empty($info[$feature])) { throw new RuntimeException("Missing GD feature: $feature"); }
            }
            $image = imagecreatetruecolor(2,2);
            imagepng($image, '/tmp/smoke.png'); imagejpeg($image, '/tmp/smoke.jpg'); imagewebp($image, '/tmp/smoke.webp');
            $zip = new ZipArchive(); $zip->open('/tmp/smoke.zip', ZipArchive::CREATE);
            $zip->addFromString('marker.txt', 'ok'); $zip->close();
            if (bcadd('1.2','2.3',1) !== '3.5' || !class_exists(IntlDateFormatter::class)) { exit(1); }
            echo json_encode([PHP_VERSION, phpversion('redis'), phpversion('apcu'), posix_geteuid()]);
        '''])
        versions = json.loads(core)
        assert versions == [php_version, redis_version, apcu_version, 1000], versions
        if self.variant == '82':
            self.run(['php', '-r', 'exit(extension_loaded("dom") && extension_loaded("soap") ? 0 : 1);'])
        assert composer_version in self.run(['composer', '--version'], env={'COMPOSER_HOME': '/tmp/composer'})
        self.run(['sh', '-ec', '''
            for tool in gcc g++ make phpize pecl vim nano clamscan supervisord gs; do
                if command -v "$tool" >/dev/null 2>&1; then echo "Unexpected runtime tool: $tool"; exit 1; fi
            done
            test ! -d /usr/local/include/php
            test -z "$(ls -A /var/lib/apt/lists)"
        '''])
        print(f'PHP {php_version}: pins, extensions, GD/ZIP, Composer, UID and clean runtime passed', flush=True)
        pg = self.create('--network', self.network, '--network-alias', 'pgsql',
                         '-e', 'POSTGRES_DB=smoke', '-e', 'POSTGRES_USER=smoke',
                         '-e', 'POSTGRES_PASSWORD=Smoke_Fake_Only1', 'postgres:17')
        mysql = self.create('--network', self.network, '--network-alias', 'mysql',
                            '-e', 'MYSQL_DATABASE=smoke', '-e', 'MYSQL_USER=smoke',
                            '-e', 'MYSQL_PASSWORD=Smoke_Fake_Only1', '-e', 'MYSQL_ROOT_PASSWORD=Root_Fake_Only1', 'mysql:8.4')
        self.docker('start', pg, mysql)
        self.run(['sh', '-ec', 'cat > /var/www/html/smoke.php'], volume=True, input_text=PHP_FIXTURE)
        fpm = self.create('--network', self.network, '--network-alias', 'fpm', '--read-only', '--cap-drop', 'ALL',
                          '--security-opt', 'no-new-privileges', '--tmpfs', '/tmp:rw,uid=1000,gid=1000',
                          '--mount', f'type=volume,source={self.volume},target=/var/www/html,readonly',
                          '-e', 'PGSQL_DSN=pgsql:host=pgsql;dbname=smoke;connect_timeout=2',
                          '-e', 'MYSQL_DSN=mysql:host=mysql;dbname=smoke;charset=utf8mb4', self.image)
        self.docker('start', fpm)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            probe = self.docker('exec', fpm, 'php', '-r', '''
                try { foreach (['PGSQL','MYSQL'] as $driver) {
                    new PDO(getenv($driver . '_DSN'), 'smoke', 'Smoke_Fake_Only1', [PDO::ATTR_TIMEOUT => 2]);
                }} catch (Throwable $e) { exit(1); }
            ''', check=False, timeout=15)
            if probe.returncode == 0:
                break
            time.sleep(2)
        else:
            raise RuntimeError('Application PDO credentials did not become ready')
        self.docker('exec', fpm, 'fpm-healthcheck')
        request_env = {'SCRIPT_FILENAME': '/var/www/html/smoke.php', 'SCRIPT_NAME': '/smoke.php', 'REQUEST_METHOD': 'GET'}
        response = self.run(['cgi-fcgi', '-bind', '-connect', 'fpm:9000'], env=request_env)
        payload = json.loads(response.split('\n\n', 1)[1])
        assert payload == {'uid': 1000, 'databases': {'pgsql': "quote' and unicode caf\u00e9", 'mysql': "quote' and unicode caf\u00e9"}}
        print('Read-only FPM and real PostgreSQL/MySQL read/write passed', flush=True)
        laravel = '12.0' if self.variant == '82' else '13.0'
        self.run(['composer', 'create-project', '--no-interaction', '--prefer-dist', f'laravel/laravel:^{laravel}', 'laravel'],
                 volume=True, env={'COMPOSER_HOME': '/tmp/composer'}, timeout=600)
        version = self.run(['php', '/var/www/html/laravel/artisan', '--version'], volume=True)
        assert version.startswith(f'Laravel Framework {laravel.split(".")[0]}.')
        self.run(['php', '/var/www/html/laravel/artisan', 'migrate', '--force'], volume=True)
        print(f'Real Laravel {laravel} install and migrations passed', flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(self.run, ['cgi-fcgi', '-bind', '-connect', 'fpm:9000'],
                                      env=dict(request_env, QUERY_STRING='slow=1'))
            for _ in range(20):
                if self.docker('exec', fpm, 'test', '-f', '/tmp/laraship-request-active', check=False).returncode == 0:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('Slow FastCGI request did not start')
            self.docker('stop', '--time', '15', fpm)
            assert pending.result(timeout=15).endswith('drained')
        assert self.docker('inspect', '--format', '{{.State.ExitCode}}', fpm).stdout.strip() == '0'
        print('Graceful SIGQUIT drained the active FastCGI request', flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--variant', choices=('82', '83'), default='83')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./:@-]*', args.image):
        parser.error('Invalid image reference')
    def interrupted(_signum, _frame):
        raise SystemExit('PHP smoke check interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    smoke = Smoke(args.image, args.variant)
    try:
        smoke.test()
    except BaseException:
        for identifier in smoke.containers:
            if smoke.docker('inspect', '--format', '{{.Config.Cmd}}', identifier, check=False).stdout.strip() == '[php-fpm]':
                print(smoke.docker('logs', '--tail', '30', identifier, check=False).stderr, flush=True)
        raise
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        smoke.cleanup()


if __name__ == '__main__':
    main()
