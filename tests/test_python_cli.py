"""Exercise installer boundaries and backend forwarding without changing the server."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import os
import select
import signal
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from laraship import cli, install


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "laraship-1.2.2.tar.gz"
        self.destination = self.root / "toolkit"

    def archive_with(self, extra=(), version="1.2.2"):
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in install.REQUIRED_FILES:
                data = (version + "\n").encode() if name == "VERSION" else b"fixture\n"
                member = tarfile.TarInfo(f"laraship-1.2.2/{name}")
                member.size = len(data)
                member.mode = 0o7777 if name.endswith(".sh") else 0o666
                archive.addfile(member, io.BytesIO(data))
            for member, data in extra:
                archive.addfile(member, io.BytesIO(data) if data is not None else None)
        return self.archive

    def fake_download(self, url, destination, limit=install.MAX_DOWNLOAD):
        if url.endswith(".sha256"):
            digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
            destination.write_text(f"{digest}  {self.archive.name}\n", encoding="ascii")
        else:
            destination.write_bytes(self.archive.read_bytes())

    def perform(self):
        with patch.object(install, "download", side_effect=self.fake_download):
            return install.install_native("1.2.2", str(self.destination))

    def test_verified_install_and_repeat_preserve_existing_files(self):
        self.archive_with()
        self.assertEqual(self.perform(), self.destination)
        self.assertEqual((self.destination / "VERSION").read_text().strip(), "1.2.2")
        if os.name == "posix":
            self.assertEqual((self.destination / "deploy-laravel.sh").stat().st_mode & 0o7777, 0o755)
        with patch.object(install, "download") as download:
            with self.assertRaisesRegex(ValueError, "already exists"):
                install.install_native("1.2.2", str(self.destination))
            download.assert_not_called()
        self.assertEqual((self.destination / "VERSION").read_text().strip(), "1.2.2")

    def test_rejects_checksum_mismatch_and_other_filename_before_destination_creation(self):
        self.archive_with()
        checksum = self.root / "sum"
        for content in (f"{'0' * 64}  {self.archive.name}",
                        f"{'0' * 64}  different.tar.gz", "malformed"):
            with self.subTest(content=content):
                checksum.write_text(content)
                with self.assertRaises(ValueError):
                    install.verify_checksum(self.archive, checksum, self.archive.name)
        self.assertFalse(self.destination.exists())

    def test_checksum_failure_does_not_publish(self):
        self.archive_with()
        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install, "verify_checksum", side_effect=ValueError("bad checksum")):
            with self.assertRaises(ValueError):
                install.install_native("1.2.2", str(self.destination))
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX modes")
    def test_permissive_umask_cannot_make_the_toolkit_world_writable(self):
        self.archive_with()
        previous = os.umask(0)
        try:
            self.perform()
        finally:
            os.umask(previous)
        for path in (self.destination, self.destination / "laravel", self.destination / "lib"):
            self.assertEqual(path.stat().st_mode & 0o7777, 0o755)
        self.assertEqual((self.destination / "VERSION").stat().st_mode & 0o7777, 0o644)

    def test_rejects_links_traversal_absolute_duplicate_and_special_members(self):
        for name, kind in (("laraship-1.2.2/../../escape", tarfile.REGTYPE),
                           ("/escape", tarfile.REGTYPE),
                           ("other/file", tarfile.REGTYPE),
                           ("laraship-1.2.2/link", tarfile.SYMTYPE),
                           ("laraship-1.2.2/hard", tarfile.LNKTYPE),
                           ("laraship-1.2.2/fifo", tarfile.FIFOTYPE),
                           ("laraship-1.2.2/VERSION", tarfile.REGTYPE)):
            with self.subTest(name=name, kind=kind):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "/tmp/escape"
                self.archive_with([(member, b"" if kind == tarfile.REGTYPE else None)])
                with self.assertRaises(ValueError):
                    self.perform()
                self.assertFalse(self.destination.exists())
                self.assertFalse((self.root / "escape").exists())

    def test_rejects_mismatched_version_missing_files_and_expansion_limit(self):
        self.archive_with(version="9.9.9")
        with self.assertRaisesRegex(ValueError, "VERSION"):
            self.perform()
        with tarfile.open(self.archive, "w:gz"):
            pass
        with self.assertRaisesRegex(ValueError, "missing"):
            self.perform()
        self.archive_with()
        with patch.object(install, "MAX_EXPANDED", 1):
            with self.assertRaisesRegex(ValueError, "size limit"):
                self.perform()
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(os.name == "posix", "POSIX symlinks")
    def test_refuses_dangling_symlink_and_symlink_parent(self):
        self.destination.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(ValueError, "symbolic"):
            install.installation_path(str(self.destination))
        self.destination.unlink()
        self.destination.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symbolic"):
            install.installation_path(str(self.destination / "new"))

    def test_concurrent_install_cannot_replace_existing_destination(self):
        self.archive_with()
        original = install.unpack_release

        def concurrent(*args):
            result = original(*args)
            self.destination.mkdir()
            (self.destination / "sentinel").write_text("keep")
            return result

        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install, "unpack_release", side_effect=concurrent):
            with self.assertRaises(FileExistsError):
                install.install_native("1.2.2", str(self.destination))
        self.assertEqual((self.destination / "sentinel").read_text(), "keep")

    def test_bad_version_and_paths_are_rejected(self):
        for value in ("latest", "../1.2.2", "1.2", "v1.2.2", "1.2.2;touch bad"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                install.release_version(value)
        for value in ("relative", "/tmp/../opt/laraship", "/tmp/a,b", "/tmp/a\nb"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                install.absolute_path(value)

    def test_failed_copy_leaves_a_marker_and_existing_path_is_refused(self):
        self.archive_with()
        with patch.object(install, "download", side_effect=self.fake_download), \
                patch.object(install.shutil, "copytree", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                install.install_native("1.2.2", str(self.destination))
        self.assertTrue((self.destination / ".laraship-installing").is_file())
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.perform()

    def test_http_download_and_downgrade_redirect_are_rejected(self):
        with self.assertRaises(ValueError):
            install.download("http://example.test/file", self.root / "download")
        with self.assertRaises(ValueError):
            install.HTTPSRedirects().redirect_request(None, None, 302, "", {}, "http://example.test/file")

    def test_download_size_limit_leaves_no_installation(self):
        response = io.BytesIO(b"too large")
        with patch.object(install, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "size or time"):
                install.download("https://example.test/file", self.root / "download", limit=2)
        self.assertFalse(self.destination.exists())


class CLITests(unittest.TestCase):
    def call(self, arguments):
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = cli.main(arguments)
        return status, output.getvalue(), errors.getvalue()

    def test_docker_install_preview_has_no_network_or_subprocess(self):
        with patch.object(cli, "require_docker") as docker, patch.object(cli, "install_native") as native:
            status, output, _ = self.call(["install", "--backend", "docker", "--dry-run"])
        self.assertEqual(status, 0)
        self.assertIn("shellharbor/laraship:", output)
        docker.assert_not_called()
        native.assert_not_called()

    def test_native_install_preview_does_not_write_or_download(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(cli, "install_native") as native:
            target = Path(temporary) / "new"
            status, _, _ = self.call(["install", "--directory", str(target), "--dry-run"])
            self.assertEqual(status, 0)
            self.assertFalse(target.exists())
            native.assert_not_called()

    def test_native_passes_arguments_as_distinct_values_and_uses_exec(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "VERSION").write_text("1.2.2")
            (root / "deploy-laravel.sh").write_text("fixture")
            arguments = ["--db-password", "private ' ; $(touch injected)", "--domain", "example.test"]
            with patch.object(cli, "require_linux"), patch.object(cli.shutil, "which", return_value="bash"), \
                    patch.object(cli.os, "execvp") as execute:
                status, output, errors = self.call(["deploy", "--directory", temporary, "--", *arguments])
            self.assertEqual(status, 0)
            execute.assert_called_once_with("bash", ["bash", str(root / "deploy-laravel.sh"), *arguments])
            self.assertEqual(output + errors, "")

    @unittest.skipUnless(sys.platform == "linux", "Linux process replacement")
    def test_native_exit_status_and_termination_reach_the_real_backend(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "VERSION").write_text("1.2.2")
            script = root / "deploy-laravel.sh"
            script.write_text("exit 23\n")
            environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "src"))
            command = [sys.executable, "-m", "laraship", "deploy", "--directory", temporary]
            self.assertEqual(subprocess.run(command, env=environment, check=False).returncode, 23)
            script.write_text("trap 'exit 42' TERM\necho ready\nwhile :; do sleep 0.1; done\n")
            process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                self.assertEqual(process.stdout.readline().strip(), "ready")
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 42)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                process.stdout.close()

    def test_docker_information_has_no_host_mounts_and_uses_read_only_runtime(self):
        with patch.object(cli, "require_docker"), patch.object(cli, "execute", return_value=0) as execute:
            status, _, _ = self.call(["deploy", "--backend", "docker", "--", "--dry-run", "--domain", "example.test"])
        self.assertEqual(status, 0)
        command = execute.call_args.args[0]
        self.assertNotIn("--mount", command)
        self.assertIn("--read-only", command)
        self.assertEqual(command[command.index("--network") + 1], "none")

    def test_docker_pull_failure_is_preserved(self):
        with patch.object(cli, "require_linux"), patch.object(cli, "require_docker"), \
                patch.object(cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 17)):
            status, _, _ = self.call(["install", "--backend", "docker"])
        self.assertEqual(status, 17)

    def test_docker_preview_can_validate_explicit_readonly_hook_inputs(self):
        args = cli.parser().parse_args(["deploy", "--backend", "docker", "--mount-readonly", "/root/hooks"])
        with patch.object(cli, "require_linux"), patch.object(cli.Path, "exists", return_value=True):
            command = cli.docker_command(args, ["--dry-run", "--on-complete", "/root/hooks/notify.sh"])
        self.assertIn("type=bind,src=/root/hooks,dst=/root/hooks,readonly", command)
        self.assertIn("--read-only", command)
        self.assertNotIn("host", command)
        self.assertNotIn("type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock", command)

    def test_docker_daemon_failures_are_actionable(self):
        with patch.object(cli.shutil, "which", return_value="docker"), \
                patch.object(cli.subprocess, "run", side_effect=subprocess.TimeoutExpired("docker", 15)):
            with self.assertRaisesRegex(ValueError, "timed out"):
                cli.require_docker()
        for response in (subprocess.CompletedProcess([], 1, "", "private raw error"),
                         subprocess.CompletedProcess([], 0, "windows\n", "")):
            with patch.object(cli.shutil, "which", return_value="docker"), \
                    patch.object(cli.subprocess, "run", return_value=response):
                with self.assertRaisesRegex(ValueError, "Linux Docker"):
                    cli.require_docker()

    def test_rejects_bad_image_before_docker_or_exec(self):
        with patch.object(cli, "require_docker") as docker, patch.object(cli, "execute") as execute:
            status, _, errors = self.call(["deploy", "--backend", "docker", "--image", "example/app:latest"])
        self.assertEqual(status, 1)
        docker.assert_not_called()
        execute.assert_not_called()
        self.assertIn("exact release", errors)

    def test_immutable_images_and_toolkit_version(self):
        self.assertEqual(cli.image_reference("example/app@sha256:" + "a" * 64), "example/app@sha256:" + "a" * 64)
        with patch.object(cli, "require_docker"), patch.object(cli, "execute", return_value=0) as execute:
            self.assertEqual(self.call(["toolkit-version", "--backend", "docker"])[0], 0)
        self.assertEqual(execute.call_args.args[0][-1], "--version")

    def test_misplaced_inspection_value_does_not_bypass_server_checks(self):
        self.assertFalse(cli.informational("deploy", ["--db-password", "--dry-run"]))
        self.assertFalse(cli.informational("remove", ["--dry-run"]))

    def test_partial_native_install_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / ".laraship-installing").touch()
            with patch.object(cli, "require_linux"), patch.object(cli, "execute") as execute:
                status, _, errors = self.call(["deploy", "--directory", temporary])
            self.assertEqual(status, 1)
            self.assertIn("incomplete", errors)
            execute.assert_not_called()

    def test_bad_extra_mount_is_rejected_before_daemon_or_writes(self):
        with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=0, create=True), \
                patch.dict(cli.os.environ, {}, clear=True), patch.object(cli.Path, "is_symlink", return_value=False), \
                patch.object(cli.Path, "exists", return_value=True), patch.object(cli.Path, "mkdir") as mkdir, \
                patch.object(cli, "require_docker") as docker:
            status, _, _ = self.call(["list", "--backend", "docker", "--mount-readonly", "/opt"])
        self.assertEqual(status, 1)
        mkdir.assert_not_called()
        docker.assert_not_called()

    def test_unprivileged_server_operation_does_not_create_directories(self):
        args = cli.parser().parse_args(["list", "--backend", "docker"])
        with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=1000, create=True), \
                patch.object(cli.Path, "mkdir") as mkdir:
            with self.assertRaisesRegex(ValueError, "require root"):
                cli.docker_command(args, [])
        mkdir.assert_not_called()

    def test_remote_daemon_and_context_are_refused_before_writes(self):
        args = cli.parser().parse_args(["list", "--backend", "docker"])
        for environment in ({"DOCKER_HOST": "ssh://example.test"}, {"DOCKER_CONTEXT": "remote"}):
            with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=0, create=True), \
                    patch.dict(cli.os.environ, environment, clear=True), patch.object(cli.Path, "mkdir") as mkdir:
                with self.assertRaises(ValueError):
                    cli.docker_command(args, [])
                mkdir.assert_not_called()

    def test_server_mounts_local_daemon_and_original_arguments(self):
        args = cli.parser().parse_args(["deploy", "--backend", "docker"])
        with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=0, create=True), \
                patch.dict(cli.os.environ, {}, clear=True), patch.object(cli.Path, "is_symlink", return_value=False), \
                patch.object(cli.Path, "exists", return_value=True), patch.object(cli.Path, "mkdir"):
            command = cli.docker_command(args, ["--slug", "fixture"])
        self.assertEqual(command[:4], ["docker", "--host", "unix:///var/run/docker.sock", "run"])
        for path in (*cli.SERVER_PATHS, "/var/backups/laraship"):
            self.assertIn(f"type=bind,src={path},dst={path}", command)
        self.assertIn("--interactive", command)
        self.assertEqual(command[-3:], ["deploy", "--slug", "fixture"])

    def test_real_terminal_is_forwarded_to_docker(self):
        args = cli.parser().parse_args(["backup", "--backend", "docker"])
        with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=0, create=True), \
                patch.dict(cli.os.environ, {}, clear=True), patch.object(cli.Path, "is_symlink", return_value=False), \
                patch.object(cli.Path, "exists", return_value=True), patch.object(cli.sys.stdin, "isatty", return_value=True), \
                patch.object(cli.sys.stdout, "isatty", return_value=True):
            command = cli.docker_command(args, ["--slug", "fixture", "restore", "dump.sql.gz"])
        self.assertIn("--tty", command)

    def test_upgrade_preview_uses_readonly_server_bindings_and_creates_no_directories(self):
        with patch.object(cli, "require_linux"), patch.object(cli.os, "geteuid", return_value=0, create=True), \
                patch.dict(cli.os.environ, {}, clear=True), patch.object(cli.Path, "is_symlink", return_value=False), \
                patch.object(cli.Path, "exists", return_value=True), patch.object(cli.Path, "mkdir") as mkdir, \
                patch.object(cli, "require_docker"), patch.object(cli, "execute", return_value=0) as execute:
            self.assertEqual(self.call(['upgrade', '--backend', 'docker', '--', '--slug', 'fixture', '--json'])[0], 0)
        command = execute.call_args.args[0]
        for path in ('/var/www', '/var/run/docker.sock'):
            self.assertIn(f'type=bind,src={path},dst={path},readonly', command)
        self.assertIn('--read-only', command)
        self.assertIn('host', command)
        self.assertFalse(any('/run/lock/laraship' in item or '/var/backups/laraship' in item for item in command))
        mkdir.assert_not_called()
        self.assertFalse(cli.informational('upgrade', ['--dry-run']))
        for value in ('--prepare', '--apply=/var/www/fixture/plan.json', '--recover', '--verify'):
            self.assertFalse(cli.upgrade_preview('upgrade', [value]))

    def test_upgrade_native_dispatch_and_static_docker_help(self):
        self.assertEqual(cli.COMMANDS['upgrade'], 'upgrade.sh')
        for value in ('--help', '-h', '--version'):
            self.assertTrue(cli.informational('upgrade', [value]))


if __name__ == "__main__":
    unittest.main()
