"""Existing proxy configuration, ownership and lifecycle regression checks."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('proxy_config', ROOT / 'lib/proxy_config.py')
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


def model():
    return {'services': {'nginxproxy': {'image': 'example/custom-proxy:1.0.0', 'container_name': 'nginxproxy',
        'restart': 'unless-stopped', 'command': 'custom-start --value $${VALUE}',
        'environment': {'TOKEN': '${PRIVATE_TOKEN}'}, 'ports': ['${HTTP_PORT:-80}:80', '443:443'],
        'networks': {'app': {'aliases': ['legacy-proxy']}},
        'volumes': ['./nginx.conf:/etc/nginx/nginx.conf:ro', 'app_ssl_certificates:/etc/letsencrypt/app:ro']}},
        'networks': {'app': {'external': True}}, 'volumes': {'app_ssl_certificates': {'external': True}}}


class NginxCompatibilityTests(unittest.TestCase):
    def test_inline_routes_are_preserved_and_include_is_idempotent(self):
        original = 'events {}\nhttp {\n server { listen 80; server_name legacy.example.test; }\n}\n'
        changed = proxy.enable_sites(original)
        added = '    # Additional sites managed by LaraShip.\n    include /etc/nginx/sites/*.conf;\n'
        self.assertEqual(changed.replace(added, ''), original)
        self.assertEqual(proxy.enable_sites(changed), changed)

    def test_quotes_comments_variables_and_nested_blocks_do_not_move_the_include(self):
        original = '# http { include /etc/nginx/sites/*.conf; }\nevents {}\nhttp { map $a $b { default "};#"; } server { return 200 "${arg_x}"; } }\n'
        changed = proxy.enable_sites(original)
        directives, closes = proxy.nginx_structure(changed)
        self.assertEqual(len(closes), 1)
        self.assertIn((('http',), ('include', '/etc/nginx/sites/*.conf')), directives)

    def test_existing_quoted_or_relative_include_is_respected(self):
        for path in ('"/etc/nginx/sites/*.conf"', 'sites/*.conf', '/etc/nginx/sites/*'):
            text = 'events {} http { include ' + path + '; }'
            self.assertEqual(proxy.enable_sites(text), text)

    def test_missing_duplicate_or_unbalanced_http_is_refused(self):
        for text in ('events {}', 'http {} http {}', 'http { server {', 'http { return 200 "unterminated; }'):
            with self.subTest(text=text), self.assertRaises(proxy.ConfigError):
                proxy.enable_sites(text)

    def test_existing_hostname_or_upstream_is_never_taken_over(self):
        for text in ('http { server { server_name APP2.EXAMPLE.TEST; } }', 'http { upstream app2 { server app_nginx; } }'):
            with self.subTest(text=text), self.assertRaises(proxy.ConfigError):
                proxy.check_conflicts([text], 'app2', 'app2.example.test')


class ComposeCompatibilityTests(unittest.TestCase):
    def test_registration_preserves_custom_runtime_and_foreign_network_options(self):
        original = model()
        changed = proxy.edit_model(copy.deepcopy(original), 'app2', 'register')
        service = changed['services']['nginxproxy']
        for key in ('image', 'container_name', 'command', 'environment', 'ports', 'restart'):
            self.assertEqual(service[key], original['services']['nginxproxy'][key])
        self.assertEqual(service['networks']['app'], {'aliases': ['legacy-proxy']})
        self.assertEqual(service['volumes'][:2], original['services']['nginxproxy']['volumes'])
        self.assertEqual(proxy.edit_model(copy.deepcopy(changed), 'app2', 'register'), changed)

    def test_implicit_default_network_survives_registration(self):
        value = model()
        value['services']['nginxproxy'].pop('networks')
        changed = proxy.edit_model(value, 'app2', 'register')
        self.assertIn('default', changed['services']['nginxproxy']['networks'])

    def test_network_lists_and_long_mounts_are_supported(self):
        value = model()
        value['services']['nginxproxy']['networks'] = ['app']
        value['services']['nginxproxy']['volumes'] = [{'type': 'bind', 'source': './nginx.conf', 'target': '/etc/nginx/nginx.conf', 'read_only': True}]
        changed = proxy.edit_model(value, 'app2', 'register')
        self.assertEqual(set(changed['services']['nginxproxy']['networks']), {'app', 'app2'})

    def test_conflicting_resource_and_host_network_mode_are_refused(self):
        for mutation in ('network', 'volume', 'target', 'host', 'internal-network', 'internal-volume', 'container-name'):
            value = model()
            if mutation == 'network':
                value['networks']['app2'] = {'name': 'other_network', 'external': True}
            elif mutation == 'volume':
                value['volumes']['app2_ssl_certificates'] = {'name': 'other_certificates', 'external': True}
            elif mutation == 'target':
                value['services']['nginxproxy']['volumes'].append('foreign:/etc/letsencrypt/app2')
            elif mutation == 'host':
                value['services']['nginxproxy']['network_mode'] = 'host'
            elif mutation == 'internal-network':
                value['networks']['app2'] = None
            elif mutation == 'internal-volume':
                value['volumes']['app2_ssl_certificates'] = None
            else:
                value['services']['nginxproxy']['container_name'] = 'operator-proxy'
            with self.subTest(mutation=mutation), self.assertRaises(proxy.ConfigError):
                proxy.edit_model(value, 'app2', 'register')

    def test_disable_and_remove_only_selected_project_connections(self):
        for action in ('disable', 'remove'):
            changed = proxy.edit_model(model(), 'app2', 'register')
            changed = proxy.edit_model(changed, 'app2', action)
            service = changed['services']['nginxproxy']
            self.assertEqual(service['networks'], {'app': {'aliases': ['legacy-proxy']}})
            self.assertEqual(service['volumes'], model()['services']['nginxproxy']['volumes'])
            self.assertEqual(changed['networks'], model()['networks'])
            self.assertEqual(changed['volumes'], model()['volumes'])

    def test_shared_resource_declarations_are_kept_for_other_services(self):
        value = proxy.edit_model(model(), 'app2', 'register')
        value['services']['other'] = {'image': 'example/other:1.0.0', 'networks': ['app2'],
            'volumes': ['app2_ssl_certificates:/cert:ro']}
        changed = proxy.edit_model(value, 'app2', 'remove')
        self.assertIn('app2', changed['networks'])
        self.assertIn('app2_ssl_certificates', changed['volumes'])

    def test_paths_and_mount_options_keep_their_live_meaning_during_staging(self):
        origin = Path('/var/www/nginxproxy')
        value = model()
        value['services']['nginxproxy']['volumes'].append('../certs:/certs:ro,z')
        value['services']['nginxproxy']['build'] = {'context': '.', 'dockerfile': 'custom.Dockerfile'}
        proxy.prepare_paths(value, origin)
        self.assertEqual(value['services']['nginxproxy']['volumes'][-1], '/var/www/certs:/certs:ro,z')
        self.assertEqual(value['services']['nginxproxy']['volumes'][0], './nginx.conf:/etc/nginx/nginx.conf:ro')
        self.assertEqual(value['services']['nginxproxy']['build'], {'context': './.', 'dockerfile': 'custom.Dockerfile'})

    def test_compose_parser_preserves_interpolation_and_environment_file_references(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'docker-compose.yml'
            path.write_text('services: {}\n')
            result = subprocess.CompletedProcess([], 0, json.dumps(model()).encode(), b'')
            with patch.object(proxy.subprocess, 'run', return_value=result) as command:
                self.assertEqual(proxy.load_model(path), model())
            arguments = command.call_args.args[0]
            for option in ('--no-interpolate', '--no-env-resolution', '--no-path-resolution', '--no-normalize'):
                self.assertIn(option, arguments)

    def test_user_overrides_are_refused_without_replacing_their_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'docker-compose.yml'
            path.write_text('services: {}\n')
            override = path.with_name('docker-compose.override.yml')
            override.write_text('custom operator configuration')
            with self.assertRaises(proxy.ConfigError):
                proxy.load_model(path)
            self.assertEqual(override.read_text(), 'custom operator configuration')

    def test_unrepresented_runtime_networks_and_aliases_are_refused(self):
        value = model()
        value['networks']['app']['name'] = 'app'
        for extra in ('network', 'alias'):
            container = {'Id': 'c' * 64, 'Config': {'Hostname': 'c' * 12}, 'NetworkSettings': {'Networks': {'app': {'Aliases': ['nginxproxy', 'legacy-proxy']}}}}
            if extra == 'network':
                container['NetworkSettings']['Networks']['unrepresented'] = {'Aliases': []}
            else:
                container['NetworkSettings']['Networks']['app']['Aliases'].append('manual-alias')
            results = [subprocess.CompletedProcess([], 0, json.dumps(value).encode(), b''),
                       subprocess.CompletedProcess([], 0, json.dumps([container]).encode(), b'')]
            with self.subTest(extra=extra), patch.object(proxy.subprocess, 'run', side_effect=results), self.assertRaises(proxy.ConfigError):
                proxy.check_runtime(Path('/candidate'), 'legacyoperator')


if __name__ == '__main__':
    unittest.main()
