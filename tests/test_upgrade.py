"""Upgrade policy, private staging, guarded apply and recoverable failure contracts."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from datetime import date
import base64
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import upgrade as engine
from upgrade_model import (UpgradeError, choose, copy_source, digest, discard, read_json,
                           recipe, tree_hash, validate_composer, version, write_json)
from upgrade_runtime import Runner


class UpgradePolicyTests(unittest.TestCase):
    def choose(self, source='12.70.2', php='8.2.35', target=None, filament=None, **options):
        packages = {'laravel/framework': source}
        if filament:
            packages['filament/filament'] = filament
        return choose(ROOT, packages, php, target, today=date(2026, 10, 28), **options)

    def test_latest_major_upgrades_php_and_filament(self):
        target = self.choose(filament='v4.1.0')
        self.assertEqual((target['laravel_constraint'], target['php'], target['filament_major']), ('^13.0', '8.3.36', 5))
        self.assertTrue(target['filament_upgrade'])

    def test_same_branch_preserves_compatible_php(self):
        self.assertEqual(self.choose(target='12.0')['php'], '8.2.35')
        self.assertEqual(self.choose(source='13.0.0', php='8.3.36')['php'], '8.3.36')

    def test_exact_patch_is_exact_and_branch_selector_is_not_a_downgrade(self):
        self.assertEqual(self.choose(target='12.70.2')['laravel_constraint'], '12.70.2')
        self.assertEqual(self.choose(target='12.0')['laravel_constraint'], '^12.0')

    def test_retired_future_unstable_and_downgraded_targets_are_refused(self):
        for target in ('9.0', '10.0', '11.0', '14.0', '13.0-beta', 'latest', '12.70.1', '12.69'):
            with self.subTest(target=target), self.assertRaises(UpgradeError):
                self.choose(target=target)
        with self.assertRaisesRegex(UpgradeError, 'downgrade'):
            self.choose(source='13.1.0', php='8.3.36', target='12.0')
        with self.assertRaises(UpgradeError):
            self.choose(minimum='14.0')

    def test_source_and_php_matrix_are_deliberately_bounded(self):
        for source, php, filament in [('11.0.0', '8.3.36', None), ('12.0.0', '8.4.27', None),
                                       ('12.0.0', '8.3.37', None), ('12.0.0', '8.3.36', '3.0.0')]:
            with self.subTest(source=source, php=php), self.assertRaises(UpgradeError):
                self.choose(source=source, php=php, filament=filament)
        with self.assertRaisesRegex(UpgradeError, 'security support'):
            choose(ROOT, {'laravel/framework': '12.0.0'}, '8.2.35', '12.0', today=date(2027, 3, 1))

    def test_recipe_updates_only_reviewed_direct_requirements(self):
        config = {'require': {'php': '^8.2', 'laravel/framework': '^12.0', 'laravel/tinker': '^2.0',
                             'filament/filament': '^4.0', 'livewire/livewire': '^3.0', 'vendor/plugin': '^1.0'},
                  'require-dev': {'phpunit/phpunit': '^11.0'}, 'scripts': {'test': 'custom'}}
        result = recipe(config, self.choose(filament='4.0.0'))
        self.assertEqual(result['require']['vendor/plugin'], '^1.0')
        self.assertEqual(result['require']['livewire/livewire'], '^4.0')
        self.assertEqual(result['require-dev']['phpunit/phpunit'], '^12.0')
        self.assertEqual(result['require-dev']['filament/upgrade'], '^5.0')
        self.assertEqual(config['require']['laravel/framework'], '^12.0')
        self.assertEqual(result['scripts'], config['scripts'])

    def test_manifest_cannot_disable_security_or_embed_authentication(self):
        bad_settings = [{'audit': {'block-insecure': False}}, {'policy': {'advisories': False}},
                        {'policy': {'advisories': {'block': False}}}, {'audit': {'ignore': ['CVE-fixture']}},
                        {'policy': {'advisories': {'ignore-severity': ['low']}}},
                        {'platform': {'php': '8.3.36'}}, {'vendor-dir': '../other'},
                        {'http-basic': {'example.test': {'password': 'synthetic'}}}, {'disable-tls': True}]
        for settings in bad_settings:
            with self.subTest(settings=settings), self.assertRaises(UpgradeError):
                validate_composer({'require': {'laravel/framework': '^13.0'}, 'config': settings})
        for repository in ({'type': 'path', 'url': '../private'}, {'url': 'https://user:synthetic@example.test'},
                           {'url': 'https://example.test?token=synthetic'}):
            with self.assertRaises(UpgradeError):
                validate_composer({'require': {'laravel/framework': '^13.0'}, 'repositories': [repository]})
        validate_composer({'require': {'laravel/framework': '^13.0'}})

    def test_abbreviated_operations_and_invalid_flag_combinations_never_reach_docker(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            engine.parser().parse_args(['--slug', 'fixture', '--pre'])
        self.assertEqual(result.exception.code, 2)
        combinations = [(['--prepare', '--json'], {}), (['--commit', 'a' * 40], {}),
                        (['--database-verified'], {}), (['--apply', '/unused/plan.json', '--laravel-version', '13.0'], {}),
                        ([], {'COMPOSE_PROJECT_NAME': 'another-project'}), ([], {'DOCKER_CONTEXT': 'remote'})]
        for arguments, environment in combinations:
            runner = Mock(spec=Runner)
            runner.names = set()
            with self.subTest(arguments=arguments, environment=environment), patch.object(engine, 'Runner', return_value=runner), \
                    patch.object(engine.sys, 'platform', 'linux'), patch.object(engine.os, 'geteuid', return_value=0, create=True), \
                    patch.dict(engine.os.environ, environment, clear=True), patch.object(engine.signal, 'signal'), redirect_stderr(io.StringIO()):
                self.assertEqual(engine.main(['--slug', 'fixture', *arguments]), 1)
                runner.docker.assert_not_called()


class UpgradeFilesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_snapshot_excludes_credentials_dependencies_and_live_runtime_data(self):
        app = self.root / 'app'
        app.mkdir()
        for name in ('.env', '.env.production', 'auth.json', '.npmrc', 'storage/secret.txt', 'vendor/lib.php',
                     'node_modules/index.js', 'public/build/assets.js', 'public/css/filament/app.css', 'bootstrap/cache/config.php',
                     '.git/config', 'modules/feature/.git/config', 'id_rsa', 'config/private.pem', 'config/private.pfx', 'app/Model.php', 'composer.json'):
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic')
        original = tree_hash(app)
        (app / '.env').write_text('different synthetic value')
        self.assertEqual(tree_hash(app), original)
        copy_source(app, self.root / 'candidate')
        self.assertEqual(sorted(str(p.relative_to(self.root / 'candidate')).replace('\\', '/')
                                for p in (self.root / 'candidate').rglob('*') if p.is_file()),
                         ['app/Model.php', 'composer.json'])

    @unittest.skipUnless(os.name == 'posix', 'POSIX symlinks and modes')
    def test_escaping_symlink_and_external_cleanup_are_refused(self):
        app = self.root / 'app'
        app.mkdir()
        (app / 'escape').symlink_to('../outside')
        with self.assertRaises(UpgradeError):
            copy_source(app, self.root / 'candidate')
        self.assertFalse((self.root / 'candidate').exists())
        with self.assertRaises(UpgradeError):
            discard(self.root, app)

    def test_json_is_atomic_private_and_rejects_nonobjects(self):
        path = self.root / 'plan.json'
        write_json(path, {'status': 'prepared'})
        write_json(path, {'status': 'failed'})
        self.assertEqual(read_json(path), {'status': 'failed'})
        if os.name == 'posix':
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        path.write_text('[]')
        with self.assertRaises(UpgradeError):
            read_json(path)

    def test_runner_redacts_raw_errors_and_bounds_runtime(self):
        runner = Runner()
        with self.assertRaises(UpgradeError) as result:
            runner.run([sys.executable, '-c', "import sys;print('laravel/synthetic-secret https://user:password@example.test');sys.exit(3)"])
        self.assertNotIn('secret', str(result.exception))
        self.assertNotIn('password', str(result.exception))
        with self.assertRaisesRegex(UpgradeError, 'timed out'):
            runner.run([sys.executable, '-c', 'import time;time.sleep(10)'], timeout=0.05)

    def test_candidate_never_mounts_production_or_socket(self):
        runner = Runner('fixture')
        with patch.object(runner, 'docker', return_value=b'') as docker, patch.object(runner, 'remove_owned'):
            runner.candidate(self.root, 'fixture-image', ['php', 'artisan', 'test'])
        arguments = docker.call_args.args
        self.assertIn('none', arguments)
        self.assertIn('--read-only', arguments)
        self.assertIn('1000:1000', arguments)
        self.assertIn('--memory', arguments)
        self.assertIn('--log-driver', arguments)
        self.assertIn('io.laraship.upgrade.role=command', arguments)
        self.assertFalse(any('docker.sock' in arg for arg in arguments))
        self.assertFalse(any('APP_ENV=production' in arg for arg in arguments))

    def test_custom_php_context_and_git_runtime_tracking_are_refused(self):
        context = self.root / 'php'
        shutil.copytree(ROOT / 'laravel/.docker/php', context)
        engine.check_php_context(context)
        (context / 'php83.Dockerfile').write_text((context / 'php83.Dockerfile').read_text() + '\nRUN echo custom\n')
        with self.assertRaises(UpgradeError):
            engine.check_php_context(context)
        for name in ('vendor/lib.php', '.env.production', 'public/build/app.js', 'storage/data.txt', '.gitmodules'):
            with self.assertRaises(UpgradeError):
                engine.validate_tracked([name])
        engine.validate_tracked(['.env.example', 'storage/logs/.gitignore', 'app/Models/User.php'])

    def test_cache_clear_preserves_source_and_rejects_a_redirected_directory(self):
        cache = self.root / 'bootstrap/cache'
        cache.mkdir(parents=True)
        (cache / 'services.php').write_text('<?php // Stale provider manifest')
        (cache / 'config.php').write_text('<?php // Stale compiled configuration')
        (cache / '.gitignore').write_text('*\n!.gitignore\n')
        engine.clear_bootstrap_cache(self.root)
        self.assertEqual([path.name for path in cache.iterdir()], ['.gitignore'])
        if os.name == 'posix':
            shutil.rmtree(cache)
            cache.symlink_to(self.root, target_is_directory=True)
            with self.assertRaises(UpgradeError):
                engine.clear_bootstrap_cache(self.root)

    def test_mismatched_cached_database_configuration_is_rejected_before_dump(self):
        runner = Mock(spec=Runner)
        runner.compose.side_effect = [b'{"services":{"db":{}}}', b'DB_NATIVE=false\n']
        with patch.object(engine, 'app_environment', side_effect=[{'DB_CONFIG_HASH': 'old'}, {'DB_CONFIG_HASH': 'different'}]):
            with self.assertRaisesRegex(UpgradeError, 'Cached and uncached'):
                engine.database_backup(self.root, self.root, {'baseline_image': 'image'}, runner)
        runner.docker.assert_not_called()

    def test_pending_encryption_key_changes_cannot_be_activated_by_cache_cleanup(self):
        runner = Mock(spec=Runner)
        before = {'DB_CONFIG_HASH': 'same-database', 'APP_KEY_HASH': 'original-key'}
        changed = {'DB_CONFIG_HASH': 'same-database', 'APP_KEY_HASH': 'pending-key'}
        with patch.object(engine, 'app_environment', side_effect=[before, changed]):
            with self.assertRaisesRegex(UpgradeError, 'encryption settings differ'):
                engine.checked_environment(runner, self.root, self.root, 'image')
        runner.docker.assert_not_called()

    def test_interrupted_command_cleanup_does_not_select_production_image_labels(self):
        runner = Runner('a' * 32)
        with patch.object(runner, 'docker', side_effect=[b'b' * 64, b'']) as docker, \
                patch.object(runner, 'remove_owned') as remove:
            runner.cleanup_owned()
        remove.assert_called_once_with('b' * 64)
        self.assertIn('label=io.laraship.upgrade.role=command', docker.call_args_list[0].args)
        with patch.object(runner, 'inspect', return_value={'Id': 'c' * 64, 'Config': {'Labels': {'io.laraship.upgrade': 'a' * 32}}}), \
                patch.object(runner, 'docker') as docker:
            runner.remove_owned('production')
        docker.assert_not_called()

    def test_readiness_uses_a_signed_cookie_without_secret_bearing_urls(self):
        app = self.root / 'public_html/storage/framework'
        app.mkdir(parents=True)
        secret = 'synthetic-maintenance-secret'
        write_json(app / 'down', {'secret': secret})
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                raw = self.headers.get('Cookie', '').removeprefix('laravel_maintenance=')
                payload = json.loads(base64.b64decode(raw))
                expected = hmac.new(secret.encode(), str(payload['expires_at']).encode(), hashlib.sha256).hexdigest()
                valid = payload['mac'] == expected and payload['expires_at'] >= time.time()
                self.send_response(200 if valid and self.path == '/ready' else 503)
                self.end_headers()
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            runner = Mock(spec=Runner)
            runner.compose.return_value = f'SITE_HOST=fixture.example.test\nSITE_PORT_HTTP={server.server_port}\n'.encode()
            engine.http_ready(runner, self.root, {'health_path': '/ready'})
            self.assertEqual(requests, ['/ready'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    @unittest.skipUnless(sys.platform == 'linux', 'Linux Git inspection')
    def test_git_planning_does_not_refresh_the_live_index(self):
        project = self.root / 'fixture'
        app = project / 'public_html'
        (app / 'vendor/composer').mkdir(parents=True)
        shutil.copytree(ROOT / 'laravel/.docker/php', project / '.docker/php')
        write_json(app / 'composer.json', {'require': {'laravel/framework': '^12.0'}})
        write_json(app / 'composer.lock', {'packages': [{'name': 'laravel/framework', 'version': 'v12.70.2'}]})
        write_json(app / 'vendor/composer/installed.json', {'packages': [{'name': 'laravel/framework', 'version': 'v12.70.2'}]})
        (app / '.gitignore').write_text('/vendor/\n.env*\n/ignored.php\n')
        (project / '.deploy-meta').write_text('REPO_BRANCH=main\n')
        runner = Runner()
        runner.run(['git', 'init', '--quiet', str(app)])
        engine.git(runner, app, 'add', '--all')
        engine.git(runner, app, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '--quiet', '-m', 'Synthetic source')
        tracked = app / 'composer.json'
        os.utime(tracked, (tracked.stat().st_atime, tracked.stat().st_mtime + 2))
        index = digest(app / '.git/index')
        build = {'context': str(project / '.docker/php'), 'dockerfile': 'php83.Dockerfile'}
        config = json.dumps({'services': {name: {'build': build, 'volumes': [{'type': 'bind', 'source': str(app), 'target': '/var/www/html'}]}
                                          for name in ('php', 'artisan', 'composer', 'nginx', 'db')}}).encode()
        def compose(path, *args):
            if args == ('config', '--format', 'json'):
                return config
            if args == ('config', '--environment'):
                return b'DB_NATIVE=false\n'
            if args[0] == 'ps':
                return b'a' * 64
            raise AssertionError(args)
        with patch.object(runner, 'compose', side_effect=compose), patch.object(runner, 'inspect', return_value={
                'Image': 'sha256:' + 'a' * 64, 'Mounts': [{'Type': 'bind', 'Source': str(app), 'Destination': '/var/www/html'}]}), \
                patch.object(runner, 'docker', return_value=b'8.3.36'):
            engine.Project('fixture', runner, www=self.root).plan(None)
            self.assertEqual(digest(app / '.git/index'), index)
            (app / 'ignored.php').write_text('<?php // Synthetic ignored application code')
            with self.assertRaisesRegex(UpgradeError, 'ignored application source'):
                engine.Project('fixture', runner, www=self.root)
        self.assertEqual(digest(app / '.git/index'), index)


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0, 'Linux root filesystem lifecycle')
class UpgradeLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / 'fixture'
        self.app = self.project / 'public_html'
        self.directory = self.project / '.laraship-upgrades' / ('a' * 32)
        self.candidate = self.directory / 'candidate'
        for app, text in ((self.app, 'original'), (self.candidate, 'candidate')):
            (app / 'bootstrap/cache').mkdir(parents=True)
            (app / 'vendor').mkdir()
            (app / 'app.txt').write_text(text)
        (self.app / 'storage/framework').mkdir(parents=True)
        (self.app / 'storage/upload.txt').write_text('persistent upload')
        (self.app / '.env').write_text('APP_KEY=synthetic-key')
        (self.project / '.docker/php').mkdir(parents=True)
        self.runner = Mock(spec=Runner)
        self.runner.compose.return_value = b'php\ncron\nqueue\n'
        self.runner.live.return_value = b'{"driver":"file","active":false}'
        self.project_object = SimpleNamespace(path=self.project, app=self.app, repository=False, runner=self.runner,
            roles=['php', 'artisan', 'composer', 'cron', 'queue'], fingerprint=lambda: 'source')
        self.state = {'id': 'a' * 32, 'schema': 1, 'slug': 'fixture', 'status': 'prepared', 'fingerprint': 'source',
                      'source_hash': tree_hash(self.candidate),
                      'candidate_hash': tree_hash(self.candidate, source=False), 'repository': False,
                      'roles': ['php', 'artisan', 'composer', 'cron', 'queue'], 'source': {'commit': None},
                      'target_image': 'sha256:' + 'b' * 64, 'baseline_image': 'sha256:' + 'c' * 64,
                      'baseline_branch': '8.2', 'target': {'php_branch': '8.3', 'php': '8.3.36'},
                      'resolved': {'laravel': '13.0.0'}, 'health_path': '/up'}
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(redirect_stdout(io.StringIO()))
        self.stack.enter_context(patch.object(engine, 'WWW', self.root))
        self.stack.enter_context(patch.object(engine, 'Project', return_value=self.project_object))
        self.stack.enter_context(patch.object(engine, 'check_image'))
        self.stack.enter_context(patch.object(engine, 'http_ready'))
        self.stack.enter_context(patch.object(engine.signal, 'signal'))
        self.stack.enter_context(patch.object(engine, 'maintenance', side_effect=self.maintenance))
        self.backup = self.stack.enter_context(patch.object(engine, 'database_backup', side_effect=self.dump))

    def maintenance(self, runner, project, directory, image, *, enable):
        path = project / 'public_html/storage/framework/down'
        if enable:
            write_json(path, {'secret': 'synthetic-token'})
        else:
            path.unlink(missing_ok=True)

    def dump(self, *args):
        self.assertTrue((self.app / 'storage/framework/down').exists())
        self.assertEqual((self.app / 'app.txt').read_text(), 'original')
        path = self.directory / 'database.dump'
        path.write_bytes(b'PGDMPsynthetic-fixture')
        return {'file': path.name, 'sha256': digest(path)}

    def test_success_preserves_runtime_data_and_keeps_private_recovery(self):
        engine.apply_upgrade(self.directory, self.state, self.runner, None)
        self.assertEqual(self.state['status'], 'completed')
        self.assertEqual((self.app / 'app.txt').read_text(), 'candidate')
        self.assertEqual((self.app / '.env').read_text(), 'APP_KEY=synthetic-key')
        self.assertEqual((self.app / 'storage/upload.txt').read_text(), 'persistent upload')
        self.assertFalse((self.app / 'storage/framework/down').exists())
        self.assertEqual((self.directory / 'previous_app/app.txt').read_text(), 'original')
        self.assertTrue((self.directory / 'database.dump').exists())

    def test_tampered_candidate_is_refused_before_maintenance_or_dump(self):
        (self.candidate / 'app.txt').write_text('tampered')
        with self.assertRaisesRegex(UpgradeError, 'changed'):
            engine.apply_upgrade(self.directory, self.state, self.runner, None)
        self.backup.assert_not_called()
        self.runner.live.assert_not_called()

    def test_backup_failure_restores_availability_without_switching(self):
        self.backup.side_effect = UpgradeError('Fixture dump failure')
        with self.assertRaises(UpgradeError):
            engine.apply_upgrade(self.directory, self.state, self.runner, None)
        self.assertEqual(self.state['status'], 'recovered')
        self.assertEqual((self.app / 'app.txt').read_text(), 'original')
        self.assertFalse((self.app / 'storage/framework/down').exists())

    def test_migration_failure_restores_code_but_retains_maintenance_until_database_review(self):
        def execute(*args, **kwargs):
            if 'migrate' in args[-1]:
                self.assertTrue(read_json(self.directory / 'plan.json')['migration_started'])
                raise UpgradeError('Fixture migration failure')
            return b'{"driver":"file","active":false}'
        self.runner.live.side_effect = execute
        with self.assertRaises(UpgradeError):
            engine.apply_upgrade(self.directory, self.state, self.runner, None)
        self.assertEqual(self.state['status'], 'needs_database_review')
        self.assertEqual((self.app / 'app.txt').read_text(), 'original')
        self.assertTrue((self.app / 'storage/framework/down').exists())
        self.assertEqual((self.app / 'storage/upload.txt').read_text(), 'persistent upload')
        engine.recover(self.directory, self.state, self.runner, database_verified=True)
        self.assertEqual(self.state['status'], 'recovered')
        self.assertFalse((self.app / 'storage/framework/down').exists())
        self.assertEqual(self.backup.call_count, 1)

    def test_stale_recovery_cannot_overwrite_a_later_upgrade(self):
        self.state['status'] = 'completed'
        write_json(self.project / 'docker-compose.override.yml', {'x-laraship-upgrade': {'id': 'later'}})
        with self.assertRaisesRegex(UpgradeError, 'different upgrade'):
            engine.recover(self.directory, self.state, self.runner, True)
        self.runner.compose.assert_not_called()

    def test_an_intentionally_stopped_worker_is_not_started_by_the_upgrade(self):
        self.runner.compose.return_value = b'php\ncron\n'
        engine.apply_upgrade(self.directory, self.state, self.runner, None)
        self.assertEqual(self.state['running_roles'], ['php', 'cron'])
        starts = [call.args[1:] for call in self.runner.compose.call_args_list if len(call.args) > 1 and call.args[1] == 'up']
        self.assertTrue(starts)
        self.assertFalse(any('queue' in arguments for arguments in starts))

    def test_git_assets_switch_and_recover_with_the_prepared_dependencies(self):
        self.project_object.repository = True
        self.state.update(repository=True, approved_commit='b' * 40, source={'commit': 'a' * 40})
        for name in engine.ASSETS:
            for app, value in ((self.app, 'original'), (self.candidate, 'candidate')):
                (app / name).mkdir(parents=True)
                (app / name / 'asset.txt').write_text(value)
        self.state['candidate_hash'] = tree_hash(self.candidate, source=False)
        def application_git(runner, app, *arguments):
            if arguments[0] == 'merge':
                (app / 'app.txt').write_text('candidate')
            if arguments[0] == 'reset':
                (app / 'app.txt').write_text('original')
            return b''
        with patch.object(engine, 'git', side_effect=application_git), patch.object(engine, 'approve_commit'):
            engine.apply_upgrade(self.directory, self.state, self.runner, 'b' * 40)
            for name in engine.ASSETS:
                self.assertEqual((self.app / name / 'asset.txt').read_text(), 'candidate')
            engine.recover(self.directory, self.state, self.runner, True)
        for name in engine.ASSETS:
            self.assertEqual((self.app / name / 'asset.txt').read_text(), 'original')

    def test_recovery_handles_interruption_between_application_directory_renames(self):
        self.maintenance(self.runner, self.project, self.directory, 'image', enable=True)
        self.state.update(status='failed', maintenance_owned=True, switch_started=True)
        os.replace(self.app, self.directory / 'previous_app')
        engine.recover(self.directory, self.state, self.runner, True)
        self.assertEqual(self.state['status'], 'recovered')
        self.assertEqual((self.app / 'app.txt').read_text(), 'original')
        self.assertEqual((self.app / 'storage/upload.txt').read_text(), 'persistent upload')


if __name__ == '__main__':
    unittest.main()
