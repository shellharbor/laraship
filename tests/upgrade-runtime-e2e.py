#!/usr/bin/env python3
"""Check command isolation, private output transport and interrupted-container cleanup."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
from upgrade import check_image
from upgrade_model import UpgradeError, write_json
from upgrade_runtime import Runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='laraship-php:upgrade-83')
    args = parser.parse_args()
    if os.environ.get('E2E_ALLOW') != '1' or sys.platform != 'linux' or os.geteuid() != 0:
        raise SystemExit('Use E2E_ALLOW=1 only on a disposable root Linux Docker server')
    runner, observer = Runner(uuid.uuid4().hex), Runner()
    image = observer.inspect('image', args.image)['Id']
    check_image(observer, image)
    identifiers, result, errors = [], [], []
    thread = None
    with tempfile.TemporaryDirectory(prefix='laraship-runtime-') as temporary:
        project = Path(temporary) / ('probe-' + runner.owner[:10])
        app = project / 'app'
        app.mkdir(parents=True)
        app.chmod(0o755)
        os.chown(app, 1000, 1000)
        def candidate():
            try:
                result.append(runner.candidate(app, image, ['php', '-r', 'echo "fixture-stdout"; fflush(STDOUT); sleep(6);']))
            except BaseException as error:
                errors.append(error)
        try:
            thread = threading.Thread(target=candidate)
            thread.start()
            identifier = b''
            for _ in range(50):
                identifier = observer.docker('ps', '--quiet', '--filter', f'label=io.laraship.upgrade={runner.owner}').strip()
                if identifier:
                    break
                time.sleep(0.05)
            assert identifier
            container = observer.inspect('container', identifier.decode())
            config = container['HostConfig']
            assert config['LogConfig']['Type'] == 'none'
            assert config['ReadonlyRootfs'] and config['Memory'] == 1073741824 and config['PidsLimit'] == 256
            assert container['Config']['User'] == '1000:1000'
            assert 'ALL' in config['CapDrop']
            assert container['Config']['Labels']['io.laraship.upgrade.role'] == 'command'
            thread.join(timeout=15)
            assert not thread.is_alive() and not errors and result == [b'fixture-stdout']
            print('PASS: real non-root/read-only/bounded command with no Docker logs and intact attached stdout', flush=True)

            (project / '.env').write_text('')
            write_json(project / 'docker-compose.yml', {'services': {'php': {'image': image,
                'working_dir': '/var/www/html', 'volumes': ['./app:/var/www/html'],
                'logging': {'driver': 'json-file', 'options': {'max-size': '10m'}}}}})
            output = runner.live(project, project, image, ['php', '-r',
                'echo getenv("APP_CONFIG_CACHE").":".stream_get_contents(STDIN);'], data=b'fixture-stdin',
                environment={'APP_CONFIG_CACHE': '/tmp/synthetic-config.php'})
            assert output == b'/tmp/synthetic-config.php:fixture-stdin'
            assert json.loads((project / 'cli-runtime.json').read_text())['services']['php']['logging']['driver'] == 'none'
            print('PASS: real Compose command preserves private stdin/environment and overrides logging options', flush=True)

            for owner, role in ((runner.owner, 'command'), (runner.owner, None), (uuid.uuid4().hex, 'command')):
                labels = ['--label', f'io.laraship.upgrade={owner}', '--label', f'io.laraship.fixture={runner.owner}']
                if role:
                    labels += ['--label', f'io.laraship.upgrade.role={role}']
                identifier = observer.docker('run', '--detach', '--network', 'none', '--read-only', '--memory', '64m',
                    *labels, '--entrypoint', 'php', image, '-r', 'sleep(120);').decode().strip()
                identifiers.append(identifier)
            runner.cleanup_owned()
            assert not observer.docker('ps', '--all', '--quiet', '--filter', f'id={identifiers[0]}').strip()
            assert observer.inspect('container', identifiers[1])['State']['Running']
            assert observer.inspect('container', identifiers[2])['State']['Running']
            print('PASS: interrupted command removed; same-owner production-like and foreign containers preserved', flush=True)
        finally:
            for name in list(runner.names):
                runner.remove_owned(name)
            if thread is not None:
                thread.join(timeout=15)
            for identifier in identifiers:
                try:
                    container = observer.inspect('container', identifier)
                except (UpgradeError, ValueError, OSError):
                    continue
                if container['Config']['Labels'].get('io.laraship.fixture') == runner.owner:
                    observer.docker('rm', '--force', identifier, check=False)


if __name__ == '__main__':
    main()
