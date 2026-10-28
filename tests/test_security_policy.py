"""Security floors must survive custom images and all deployment adapters."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'laravel/.docker/php/security-policy.php'
SPEC = importlib.util.spec_from_file_location('security_k8s', ROOT / 'kubernetes/laraship.py')
K8S = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(K8S)


class SecurityPolicyTests(unittest.TestCase):
    def test_all_php_bases_have_reviewed_security_pins(self):
        floors = {(8, 2): 35, (8, 3): 36, (8, 4): 27, (8, 5): 12}
        paths = [*ROOT.glob('laravel/.docker/php/*.Dockerfile'), ROOT / 'kubernetes/application/Dockerfile']
        self.assertEqual(len(paths), 3)
        for path in paths:
            with self.subTest(path=path):
                source = path.read_text(encoding='utf-8')
                pins = re.findall(r'^FROM php:(\d+)\.(\d+)\.(\d+)-\S+@sha256:[a-f0-9]{64}', source, re.M)
                self.assertEqual(len(pins), 1)
                major, minor, patch = map(int, pins[0])
                self.assertIn((major, minor), floors)
                self.assertGreaterEqual(patch, floors[major, minor])
                self.assertIn('RUN php /usr/local/share/laraship/security-policy.php', source)

    def test_standalone_kubernetes_policy_matches_shared_source(self):
        dockerfile = (ROOT / 'kubernetes/application/Dockerfile').read_text(encoding='utf-8')
        embedded = dockerfile.split("<<'LARASHIP_SECURITY_POLICY' /usr/local/share/laraship/security-policy.php\n", 1)[1]
        embedded = embedded.split('\nLARASHIP_SECURITY_POLICY\n', 1)[0] + '\n'
        self.assertEqual(embedded, POLICY.read_text(encoding='utf-8'))

    def test_every_kubernetes_workload_checks_actual_image_before_startup(self):
        args = K8S.parser().parse_args(['render', '--name', 'site', '--namespace', 'site',
            '--configmap', 'site-config', '--secret', 'site-secret', '--revision', 'v1',
            '--image', 'custom/image:1', '--worker'])
        for resource in K8S.resources(args):
            if resource['kind'] not in ('Deployment', 'Job'):
                continue
            with self.subTest(name=resource['metadata']['name']):
                pod = resource['spec']['template']['spec']
                guard = pod['initContainers'][0]
                self.assertEqual(guard['image'], args.image)
                self.assertEqual(guard['command'][:2], ['php', '-r'])
                self.assertIn(POLICY.read_text(encoding='utf-8').removeprefix('<?php'), guard['command'][2])
                self.assertTrue(guard['command'][2].endswith('laraship_security_main(["/app/composer.lock"]);'))
                self.assertTrue(guard['securityContext']['readOnlyRootFilesystem'])
                self.assertEqual(guard['envFrom'], pod['containers'][0]['envFrom'])


if __name__ == '__main__':
    unittest.main()
