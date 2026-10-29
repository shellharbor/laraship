"""Exercise fixture behavior when database startup is slow or a worker fails."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('upgrade_e2e_fixture', Path(__file__).with_name('upgrade-e2e.py'))
fixture_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_module)


class DelayedDatabase:
    image = 'sha256:' + 'a' * 64

    def __init__(self, *, broken_worker=False):
        self.migrations = 0
        self.migrated = self.seeded = False
        self.running = {}
        self.broken_worker = broken_worker

    def candidate(self, app, image, arguments, **options):
        for name in ('routes', 'app', 'storage/app'):
            (app / name).mkdir(parents=True, exist_ok=True)
        (app / 'routes/web.php').write_text('<?php\n')

    def compose(self, project, *arguments, **options):
        if arguments[0] == 'up':
            for role in ('php', 'nginx', 'db', 'cron', 'queue'):
                if role in arguments:
                    # A worker which starts early exits and has no restart policy.
                    self.running[role] = (self.migrated and self.seeded and not self.broken_worker) if role == 'queue' else True
        elif arguments[0] == 'run' and 'migrate' in arguments:
            self.migrations += 1
            if self.migrations == 1:
                raise fixture_module.engine.UpgradeError('Synthetic database is still initializing')
            self.migrated = True
        elif arguments[0] == 'exec':
            assert self.migrated
            self.seeded = True
        elif arguments[0] == 'ps':
            role = arguments[-1]
            return (role.encode() + b'\n') if self.running.get(role) else b''
        return b''

    def inspect(self, kind, identifier):
        return {'Id': self.image} if kind == 'image' else {'Image': self.image}


class UpgradeFixtureTests(unittest.TestCase):
    def exercise(self, runner):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        fixture = fixture_module.Fixture('mysql', '82', None, False)
        fixture.path = Path(temporary.name) / fixture.slug
        fixture.app = fixture.path / 'public_html'
        fixture.upstream = fixture.path / 'upstream'
        fixture.runner = runner
        fixture.wait_http = lambda: None
        with patch.object(fixture_module.os, 'chown', create=True), \
                patch.object(fixture_module.engine, 'own'), patch.object(fixture_module.time, 'sleep'):
            fixture.create()

    def test_slow_database_is_migrated_and_seeded_before_worker_start(self):
        runner = DelayedDatabase()
        self.exercise(runner)
        self.assertEqual(runner.migrations, 2)
        self.assertTrue(runner.running['queue'])

    def test_failed_worker_is_reported_before_testing_an_upgrade(self):
        with self.assertRaisesRegex(RuntimeError, 'queue is not running'):
            self.exercise(DelayedDatabase(broken_worker=True))


if __name__ == '__main__':
    unittest.main()
