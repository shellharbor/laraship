import contextlib
import importlib.util
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("endpoint", ROOT / "lib/endpoint.py")
endpoint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(endpoint)
SECRET = 'quoted"\\value # ${LITERAL} caf\u00e9 \U0001f512'
VALUES = ["site", "example.test", "laravel", "13.0", "postgres", "8080", "8443", "9000", "6379",
          SECRET, "5432", "app", "appuser", SECRET, "true", "authuser", SECRET,
          "false", "", "/var/www/site"]


class EndpointEncodingTests(unittest.TestCase):
    def test_https_urls_and_explicit_http(self):
        for url in ("https://example.test/deploy?token=private", "HTTPS://example.test:443/", "https://[::1]:9443/"):
            endpoint.validate_url(url)
        with self.assertRaisesRegex(ValueError, "--allow-insecure-endpoint"):
            endpoint.validate_url("http://127.0.0.1:8080/")
        endpoint.validate_url("http://127.0.0.1:8080/", allow_http=True)

    def test_invalid_urls_are_rejected_even_with_http_opt_in(self):
        for url in ("", "example.test", "//example.test", "ftp://example.test/", "file:///tmp/data",
                    "https:///path", "https://user:private@example.test/", "https://example.test:private/",
                    "https://example.test:0/", "https://example.test:65536/", "https://[invalid/",
                    " https://example.test/", "https://example.test/a b", "https://example.test/\ntrace=private",
                    "https://example.test/\x00private", "https://example.test/\x7fprivate"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                endpoint.validate_url(url, allow_http=True)

    def test_url_validation_cli_never_echoes_rejected_input(self):
        for url in ("http://example.test/SECRET_MARKER", "https://example.test:SECRET_MARKER/",
                    "https://user:SECRET_MARKER@example.test/", "https://example.test/\nSECRET_MARKER"):
            result = subprocess.run([os.sys.executable, str(ROOT / "lib/endpoint.py"), "--validate-url"],
                                    input=url, text=True, encoding="utf-8", capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("SECRET_MARKER", result.stdout + result.stderr)

    def test_original_json_encoding_contract_is_preserved(self):
        result = subprocess.run([os.sys.executable, str(ROOT / "lib/endpoint.py")],
                                input="\0".join(VALUES) + "\0", text=True, encoding="utf-8", capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), endpoint.build_payload(VALUES))

    def test_curl_input_preserves_quotes_unicode_and_literal_escapes(self):
        url = 'https://example.test/deploy?token=private"value\\tail'
        config = endpoint.curl_config(url, VALUES).splitlines()
        self.assertEqual(len(config), 2)
        self.assertEqual(json.loads(config[0].removeprefix("url = ")), url)
        payload = json.loads(json.loads(config[1].removeprefix("data-binary = ")))
        self.assertEqual(payload, endpoint.build_payload(VALUES))


@unittest.skipUnless(os.name == "posix" and all(shutil.which(name) for name in ("bash", "curl", "openssl")),
                     "Live endpoint checks require Linux Bash, curl and OpenSSL")
class EndpointTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="laraship-endpoint-")
        cls.addClassCleanup(cls.work.cleanup)
        cls.directory = Path(cls.work.name)
        cls.cert, cls.key = cls.directory / "cert.pem", cls.directory / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(cls.key), "-out", str(cls.cert)],
                       check=True, capture_output=True, timeout=30)

    @contextlib.contextmanager
    def receiver(self, *, tls=False, status=200, location=None):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                requests.append((self.path, self.headers["Content-Type"], json.loads(body)))
                self.send_response(status)
                if location:
                    self.send_header("Location", location)
                self.end_headers()
                self.wfile.write(body)  # A receiver may echo the entire secret payload.

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

    def send(self, url, *, allow_http=False, trusted=True, home=None):
        env = dict(os.environ, TEST_ENDPOINT_URL=url, TEST_ENDPOINT_SECRET=SECRET,
                   TEST_ENDPOINT_ALLOW_HTTP=str(allow_http).lower(), NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        if trusted:
            env["CURL_CA_BUNDLE"] = str(self.cert)
        else:
            for key in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
                env.pop(key, None)
        if home:
            env.update(HOME=str(home), CURL_HOME=str(home))
        result = subprocess.run(["bash", "-c", '''
            source "$1"
            ENDPOINT="$TEST_ENDPOINT_URL"; ALLOW_INSECURE_ENDPOINT="$TEST_ENDPOINT_ALLOW_HTTP"
            SLUG=site; DOMAIN=example.test; LARAVEL_VERSION=13.0; DB_TYPE=postgres
            DB_POSTGRES_NAME=app; DB_POSTGRES_USER=appuser; DB_POSTGRES_PASSWORD="$TEST_ENDPOINT_SECRET"
            PORT_HTTP=8080; PORT_HTTPS=8443; PORT_PHP=9000; PORT_REDIS=6379; PORT_POSTGRES=5432
            REDIS_PASSWORD="$TEST_ENDPOINT_SECRET"; ENABLE_BASIC_AUTH=true
            AUTH_USER=authuser; AUTH_PASSWORD="$TEST_ENDPOINT_SECRET"; OBTAIN_SSL=false
            send_project_data
        ''', "_", str(ROOT / "deploy-laravel.sh")], env=env, text=True, encoding="utf-8", capture_output=True, timeout=30)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertNotIn("URL_SECRET", result.stdout + result.stderr)
        return result

    def test_verified_https_delivers_exact_payload_without_logging_echo(self):
        with self.receiver(tls=True) as (url, requests):
            result = self.send(url + "/deploy?token=URL_SECRET&range=[1-2]")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("successfully (HTTP 200)", result.stdout)
            self.assertEqual(requests, [("/deploy?token=URL_SECRET&range=[1-2]", "application/json", endpoint.build_payload(VALUES))])

    def test_http_is_refused_before_request_without_opt_in(self):
        with self.receiver() as (url, requests):
            result = self.send(url + "/URL_SECRET")
            self.assertEqual(result.returncode, 1)
            self.assertIn("--allow-insecure-endpoint", result.stderr)
            self.assertEqual(requests, [])

    def test_explicit_http_delivers_literal_payload_and_discards_error_body(self):
        with self.receiver(status=500) as (url, requests):
            result = self.send(url + "/URL_SECRET", allow_http=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("HTTP 500", result.stdout)
            self.assertEqual(requests[0][2], endpoint.build_payload(VALUES))

    def test_http_opt_in_does_not_disable_https_certificate_verification(self):
        with self.receiver(tls=True) as (url, requests):
            result = self.send(url + "/URL_SECRET", allow_http=True, trusted=False)
            self.assertEqual(result.returncode, 0)
            self.assertIn("connection or TLS error", result.stdout)
            self.assertEqual(requests, [])

    def test_https_redirect_never_forwards_payload_even_with_http_opt_in(self):
        with self.receiver() as (other, other_requests):
            with self.receiver(tls=True, status=307, location=other + "/URL_SECRET") as (url, requests):
                result = self.send(url, allow_http=True)
                self.assertIn("HTTP 307", result.stdout)
                self.assertEqual(len(requests), 1)
                self.assertEqual(other_requests, [])

    def test_user_curl_configuration_cannot_enable_redirects_or_traces(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as name:
            home = Path(name)
            trace = home / "trace.log"
            (home / ".curlrc").write_text(f'location\ninsecure\ntrace-ascii = "{trace}"\n', encoding="utf-8")
            with self.receiver() as (other, other_requests):
                with self.receiver(tls=True, status=307, location=other) as (url, requests):
                    result = self.send(url, home=home)
                    self.assertIn("HTTP 307", result.stdout)
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(other_requests, [])
                    self.assertFalse(trace.exists())


if __name__ == "__main__":
    unittest.main()
