"""Real shell-exit, callback and loopback API checks with synthetic credentials."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Reuse the shell/API tests against the actual Docker image's packaged engine.
ROOT = Path(os.environ.get("LARASHIP_COMPLETION_TEST_ROOT", Path(__file__).resolve().parents[1])).resolve()
sys.path.insert(0, str(ROOT / "lib"))
import completion

SECRET = 'fixture-password-quote"\\ ${LITERAL} caf\u00e9'
TOKEN = "fixture-private-bearer-token"

HARNESS = r'''
source "$1/deploy-laravel.sh"
WWW_DIR="$TEST_WORK/www"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$TEST_WORK/locks"
check_root() { :; }
ensure_www_dir() { mkdir -p "$WWW_DIR"; }
ss() { :; }  # Port probing is replaced below; the fixture does not need iproute2.
for fn in assign_ports validate_port_values check_port_availability install_docker create_dhparam \
          comment_ssl_blocks create_native_database build_and_start_project configure_laravel_env \
          install_modules check_project_http restart_nginxproxy obtain_ssl_certificate send_project_data print_summary; do
    eval "$fn() { :; }"
done
create_project() { PROJECT_DIR="$WWW_DIR/$SLUG"; mkdir "$PROJECT_DIR"; }
install_laravel() {
    local ignored
    ignored="$(printf subshell)"; (true)
    case "${TEST_FAILURE:-}" in
        application) return 17 ;;
        signal) touch "$TEST_WORK/ready"; while :; do sleep 0.1; done ;;
        guarded) runtime_guarded sh -c 'touch "$TEST_WORK/ready"; sleep 20' ;;
    esac
}
run_post_deploy() { if [[ "${TEST_FAILURE:-}" == post_deploy ]]; then POST_DEPLOY_FAILED=true; fi; return 0; }
create_project_backup() {
    if [[ "${TEST_FAILURE:-}" == archive ]]; then return 19; fi
    BACKUP_FILE_PATH="$TEST_WORK/project.zip"
}
shift
main "$@"
'''


class CompletionEncodingTests(unittest.TestCase):
    def values(self, **extra):
        values = dict(COMPLETION_EXIT_CODE="0", COMPLETION_STAGE="complete", COMPLETION_STARTED_EPOCH="1",
                      DB_TYPE="postgres", DB_POSTGRES_PASSWORD=SECRET, REDIS_PASSWORD=SECRET,
                      DB_MYSQL_ROOT_PASSWORD="root-secret", DB_ROOT_PASSWORD="root-secret",
                      ENABLE_BASIC_AUTH="true", AUTH_PASSWORD=SECRET, COMPLETION_FILAMENT="true",
                      FILAMENT_PASSWORD=SECRET, SLUG="site", DOMAIN="example.test")
        values.update(extra)
        return values

    def test_secrets_omitted_by_default_and_root_passwords_never_included(self):
        public = completion.build_report(self.values())
        self.assertNotIn(SECRET, json.dumps(public, ensure_ascii=False))
        private = completion.build_report(self.values(COMPLETION_INCLUDE_SECRETS="true"))
        self.assertEqual(private["database"]["password"], SECRET)
        self.assertEqual(private["filament"]["password"], SECRET)
        self.assertNotIn("root-secret", json.dumps(private))

    def test_partial_failure_keeps_unknown_ports_null(self):
        report = completion.build_report(self.values(COMPLETION_EXIT_CODE="17", COMPLETION_STAGE="application_install"))
        self.assertEqual((report["status"], report["exit_code"]), ("failed", 17))
        self.assertIsNone(report["ports"]["http"])
        self.assertFalse(report["readiness"]["http_checked"])

    def test_snapshot_preserves_literal_values_and_refuses_malformed_frames(self):
        self.assertEqual(completion.snapshot(b"PASSWORD\0" + SECRET.encode() + b"\0"), {"PASSWORD": SECRET})
        for data in (b"KEY\0value", b"KEY\0", b"KEY\0one\0KEY\0two\0", b"x" * (1024 * 1024 + 1)):
            with self.assertRaises(ValueError):
                completion.snapshot(data)

    def test_transport_keeps_credentials_url_and_token_out_of_child_arguments(self):
        values = self.values(COMPLETION_ENDPOINT="https://example.test/URL_SECRET", COMPLETION_TIMEOUT="30",
                             COMPLETION_TOKEN_FILE="/private/token", COMPLETION_INCLUDE_SECRETS="true")
        output = io.StringIO()
        with patch.object(completion, "bearer_token", return_value=TOKEN), \
                patch.object(completion, "bounded_process", return_value=(0, b"201")) as process, \
                contextlib.redirect_stdout(output):
            completion.deliver(values)
        arguments = process.call_args.args[0]
        data = process.call_args.kwargs["data"].decode("utf-8")
        self.assertEqual(arguments[:2], ["curl", "-q"])
        for private in (SECRET, TOKEN, "URL_SECRET"):
            self.assertNotIn(private, " ".join(arguments) + output.getvalue())
        self.assertIn(TOKEN, data)
        self.assertIn("URL_SECRET", data)


@unittest.skipUnless(os.name == "posix" and all(shutil.which(tool) for tool in ("bash", "python3", "curl", "openssl", "flock")),
                     "Completion integration checks require Linux shell tools")
class CompletionIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert_work = tempfile.TemporaryDirectory(prefix="laraship-completion-cert-")
        cls.addClassCleanup(cls.cert_work.cleanup)
        cls.cert = Path(cls.cert_work.name) / "cert.pem"
        cls.key = Path(cls.cert_work.name) / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(cls.key), "-out", str(cls.cert)], check=True, capture_output=True, timeout=30)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="laraship-completion-")
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)
        self.hook = self.directory / "notify.sh"
        self.result = self.directory / "result.json"
        self.count = self.directory / "count"
        self.token = self.directory / "token"
        self.token.write_text(TOKEN + "\n")
        self.token.chmod(0o600)
        self.write_hook('cat > "$TEST_WORK/result.json"\necho done >> "$TEST_WORK/count"\n')

    def write_hook(self, code):
        self.hook.write_text("#!/bin/bash\nset -e\n" + code, encoding="utf-8")
        self.hook.chmod(0o700)

    def command(self, extra=(), *, failure=""):
        arguments = ["--slug", "site", "--domain", "site.example.test", "--db-type", "postgres", "--no-ssl",
                     "--db-postgres-password", SECRET, "--redis-password", SECRET, *extra]
        environment = dict(os.environ, TEST_WORK=str(self.directory), TEST_FAILURE=failure,
                           SITE_SCHEME="https", CURL_CA_BUNDLE=str(self.cert),
                           NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        return ["bash", "-c", HARNESS, "_", str(ROOT), *arguments], environment

    def deploy(self, extra=(), *, failure=""):
        command, environment = self.command(extra, failure=failure)
        result = subprocess.run(command, env=environment, capture_output=True, text=True, encoding="utf-8", timeout=15)
        for private in (SECRET, TOKEN, "URL_SECRET"):
            self.assertNotIn(private, result.stdout + result.stderr)
        return result

    @contextlib.contextmanager
    def receiver(self, *, tls=True, status=201, redirect=False, delay=0):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                report = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, self.headers.get("Authorization"), self.headers.get("Idempotency-Key"), report))
                time.sleep(delay)
                self.send_response(status)
                if redirect:
                    self.send_header("Location", "/redirected")
                self.end_headers()
                try:
                    self.wfile.write((SECRET + TOKEN).encode())
                except (OSError, ssl.SSLError):
                    pass

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        if tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(self.cert, self.key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"{'https' if tls else 'http'}://127.0.0.1:{server.server_port}", requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_success_runs_once_after_archive_and_releases_project_lock(self):
        self.write_hook('flock -n "$TEST_WORK/locks/project-site.lock" true\ncat > "$TEST_WORK/result.json"\necho done >> "$TEST_WORK/count"\n')
        result = self.deploy(["--on-complete", str(self.hook)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(self.result.read_text())
        self.assertEqual((report["status"], report["stage"]), ("success", "complete"))
        self.assertEqual(report["archive_path"], str(self.directory / "project.zip"))
        self.assertEqual(self.count.read_text().splitlines(), ["done"])
        self.assertTrue(report["readiness"]["http_checked"])
        self.assertFalse(report["ssl"]["enabled"])

    def test_early_and_late_failures_preserve_the_original_status(self):
        for failure, code, stage in (("application", 17, "application_install"), ("archive", 19, "archive"),
                                     ("post_deploy", 1, "post_deploy")):
            with self.subTest(failure=failure):
                shutil.rmtree(self.directory / "www", ignore_errors=True)
                result = self.deploy(["--on-complete", str(self.hook)], failure=failure)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                report = json.loads(self.result.read_text())
                self.assertEqual((report["status"], report["exit_code"], report["stage"]), ("failed", code, stage))

    def test_callback_failure_and_output_do_not_override_success(self):
        self.write_hook(f'echo \'{TOKEN}\'\necho \'{TOKEN}\' >&2\nexit 9\n')
        result = self.deploy(["--on-complete", str(self.hook)])
        self.assertEqual(result.returncode, 0)
        self.assertIn("script failed", result.stdout)

    def test_callback_timeout_is_bounded_and_preserves_deployment_status(self):
        self.write_hook("sleep 20\n")
        started = time.monotonic()
        result = self.deploy(["--on-complete", str(self.hook), "--completion-timeout", "1"])
        self.assertEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 6)
        self.assertIn("timed out", result.stdout)

    def test_help_and_dry_run_do_not_invoke_callback(self):
        for argument in ("--help", "--dry-run"):
            result = self.deploy(["--on-complete", str(self.hook), argument])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.result.exists())

    def test_invalid_configuration_never_starts_deployment_or_callback(self):
        cases = (["--completion-endpoint", "http://127.0.0.1/URL_SECRET"],
                 ["--on-complete", str(self.hook), "--completion-timeout", "0"],
                 ["--completion-token-file", str(self.token)], ["--completion-include-secrets"])
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.deploy(arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.directory / "www/site").exists())
                self.assertFalse(self.result.exists())

    def test_writable_script_or_token_and_symlink_are_refused(self):
        self.hook.chmod(0o777)
        self.assertNotEqual(self.deploy(["--on-complete", str(self.hook)]).returncode, 0)
        self.hook.chmod(0o700)
        link = self.directory / "link.sh"
        link.symlink_to(self.hook)
        self.assertNotEqual(self.deploy(["--on-complete", str(link)]).returncode, 0)
        self.token.chmod(0o644)
        result = self.deploy(["--completion-endpoint", "https://example.test", "--completion-token-file", str(self.token)])
        self.assertNotEqual(result.returncode, 0)

    def test_both_targets_receive_the_same_private_report_after_failure(self):
        with self.receiver() as (url, requests):
            result = self.deploy(["--on-complete", str(self.hook), "--completion-endpoint", url + "/URL_SECRET",
                                  "--completion-token-file", str(self.token), "--completion-include-secrets"], failure="application")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        report = json.loads(self.result.read_text())
        self.assertEqual(requests, [("/URL_SECRET", "Bearer " + TOKEN, report["run_id"], report)])
        self.assertEqual(report["database"]["password"], SECRET)

    def test_https_report_omits_passwords_by_default(self):
        with self.receiver() as (url, requests):
            result = self.deploy(["--completion-endpoint", url])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)
        self.assertNotIn(SECRET, json.dumps(requests[0][3], ensure_ascii=False))

    def test_http_opt_in_and_redirects_do_not_change_success(self):
        with self.receiver(tls=False, status=302, redirect=True) as (url, requests):
            result = self.deploy(["--completion-endpoint", url + "/URL_SECRET", "--allow-insecure-endpoint"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)
        self.assertIn("HTTP 302", result.stdout)

    def test_http_opt_in_does_not_bypass_https_certificate_verification(self):
        with self.receiver() as (url, requests):
            command, environment = self.command(["--completion-endpoint", url, "--allow-insecure-endpoint"])
            for variable in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
                environment.pop(variable, None)
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests, [])
        self.assertIn("delivery failed", result.stdout)
        self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_endpoint_timeout_preserves_success(self):
        with self.receiver(delay=3) as (url, _requests):
            result = self.deploy(["--completion-endpoint", url, "--completion-timeout", "1"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("delivery failed", result.stdout)

    def test_failed_script_does_not_skip_endpoint(self):
        self.write_hook("exit 8\n")
        with self.receiver() as (url, requests):
            result = self.deploy(["--on-complete", str(self.hook), "--completion-endpoint", url])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)

    def test_timed_out_script_does_not_skip_endpoint(self):
        self.write_hook("sleep 20\n")
        with self.receiver() as (url, requests):
            result = self.deploy(["--on-complete", str(self.hook), "--completion-endpoint", url,
                                  "--completion-timeout", "1"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)

    def test_token_header_injection_is_refused_before_request(self):
        self.token.write_text(TOKEN + "\nX-Injected: value\n")
        with self.receiver() as (url, requests):
            result = self.deploy(["--completion-endpoint", url, "--completion-token-file", str(self.token)])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(requests, [])

    def test_config_completion_settings_and_cli_overrides(self):
        config = self.directory / "deploy.conf"
        config.write_text(f"ON_COMPLETE={self.hook}\nCOMPLETION_TIMEOUT=0\nCOMPLETION_INCLUDE_SECRETS=false\n")
        config.chmod(0o600)
        result = self.deploy(["--config", str(config), "--completion-timeout", "2", "--completion-include-secrets"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.result.read_text())["database"]["password"], SECRET)

    def test_term_is_reported_once_for_direct_and_guarded_work(self):
        for failure, code in (("signal", 143), ("guarded", 1)):
            with self.subTest(failure=failure):
                shutil.rmtree(self.directory / "www", ignore_errors=True)
                self.count.unlink(missing_ok=True)
                self.result.unlink(missing_ok=True)
                (self.directory / "ready").unlink(missing_ok=True)
                command, environment = self.command(["--on-complete", str(self.hook)], failure=failure)
                process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not (self.directory / "ready").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((self.directory / "ready").exists())
                    process.send_signal(signal.SIGTERM)
                    output, errors = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, code, output + errors)
                    report = json.loads(self.result.read_text())
                    self.assertEqual((report["status"], report["signal"]), ("cancelled", "TERM"))
                    self.assertEqual(self.count.read_text().splitlines(), ["done"])
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
