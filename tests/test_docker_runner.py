#!/usr/bin/env python3
"""The CLI must not act on another filesystem/network or bypass shared locks."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("preflight", Path(__file__).resolve().parents[1] / "docker-preflight.py")
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


class ContainerRunnerTests(unittest.TestCase):
    def run_preflight(self, container):
        response = subprocess.CompletedProcess([], 0, json.dumps([container]))
        with patch.object(preflight.os, "geteuid", return_value=0, create=True), patch.object(preflight.Path, "read_text", return_value=f"/var/lib/docker/containers/{'a' * 64}/hostname /etc/hostname"), patch.dict(preflight.os.environ, {}, clear=True), patch.object(preflight.subprocess, "run", return_value=response):
            return preflight.main()

    def container(self):
        return {"HostConfig": {"NetworkMode": "host"}, "Mounts": [
            {"Destination": path, "Source": path, "Type": "bind", "RW": True}
            for path in ("/var/www", "/run/lock/laraship", "/var/run/docker.sock", "/var/backups/laraship")]}

    def test_correct_server_mapping_is_accepted(self):
        self.assertEqual(self.run_preflight(self.container()), 0)

    def test_other_source_path_missing_lock_or_ephemeral_archives_fail(self):
        for position in range(4):
            with self.subTest(position=position):
                container = self.container()
                container["Mounts"][position]["Type"] = "volume"
                with self.assertRaises(ValueError):
                    self.run_preflight(container)
        container = self.container()
        container["Mounts"][0]["Source"] = "/another-directory"
        with self.assertRaises(ValueError):
            self.run_preflight(container)

    def test_isolated_network_cannot_check_host_ports(self):
        container = self.container()
        container["HostConfig"]["NetworkMode"] = "bridge"
        with self.assertRaises(ValueError):
            self.run_preflight(container)


if __name__ == "__main__":
    unittest.main()
