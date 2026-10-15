import copy
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_publication", Path(__file__).parents[1] / ".github/scripts/publish-release.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
SHA = "a" * 40


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.notes = root / "notes.md"
        self.notes.write_text("Patch release notes\n", encoding="utf-8")
        self.assets = [root / "laraship-1.1.1.tar.gz", root / "laraship-1.1.1.tar.gz.sha256"]
        for path, data in zip(self.assets, [b"synthetic archive", b"synthetic checksum"]):
            path.write_bytes(data)
        self.tag = "v1.1.1"
        self.remote = None
        self.remote_sha = SHA
        self.calls = []
        self.create_error = False
        self.upload_error = False
        self.patches = [
            patch.object(publication, "command", return_value=subprocess.CompletedProcess([], 0, SHA + "\n", "")),
            patch.object(publication, "api", side_effect=self.api),
            patch.object(publication, "gh", side_effect=self.gh),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def record(self, path):
        return dict(name=path.name, size=path.stat().st_size, state="uploaded", digest=publication.digest(path))

    def release(self, assets=()):
        return dict(tag_name=self.tag, draft=False, immutable=False,
                    body="Keep manual release notes", assets=[self.record(path) for path in assets])

    def api(self, endpoint, **kwargs):
        if "/commits/" in endpoint:
            return {"sha": self.remote_sha}
        return copy.deepcopy(self.remote)

    def gh(self, *args):
        self.calls.append(args)
        if args[:2] == ("release", "create"):
            self.remote = self.release(self.assets)
            if self.create_error:
                raise publication.PublicationError("release already exists")
        elif args[:2] == ("release", "upload"):
            paths = [Path(value) for value in args[3:args.index("--repo")]]
            self.remote["assets"].extend(self.record(path) for path in paths)
            if self.upload_error:
                raise publication.PublicationError("upload response was lost")
        elif args[:2] == ("release", "download"):
            name = args[args.index("--pattern") + 1]
            directory = Path(args[args.index("--dir") + 1])
            source = next(path for path in self.assets if path.name == name)
            (directory / name).write_bytes(source.read_bytes())
        else:
            self.fail(f"Unexpected mutation: {args}")
        return ""

    def publish(self):
        with redirect_stdout(io.StringIO()):
            publication.publish("owner/repo", self.tag, self.notes, self.assets)

    def test_fresh_release_verifies_tag_and_uploads_both_assets(self):
        self.publish()
        self.assertEqual(self.calls[0][:3], ("release", "create", self.tag))
        self.assertIn("--verify-tag", self.calls[0])
        self.assertIn(str(self.assets[0]), self.calls[0])
        self.assertIn(str(self.assets[1]), self.calls[0])
        self.assertNotIn("--prerelease", self.calls[0])

    def test_prerelease_is_marked_on_creation(self):
        self.tag = "v1.1.1-rc.1"
        self.publish()
        self.assertIn("--prerelease", self.calls[0])

    def test_flag_shaped_filename_is_passed_as_a_file_not_a_cli_option(self):
        previous = Path.cwd()
        try:
            os.chdir(self.directory.name)
            path = Path("--clobber")
            path.write_bytes(b"synthetic file")
            self.assets = [path]
            self.publish()
            self.assertNotIn("--clobber", self.calls[0])
            self.assertIn(str(path.absolute()), self.calls[0])
        finally:
            os.chdir(previous)

    def test_existing_empty_release_is_completed_and_rerun_is_read_only(self):
        self.remote = self.release()
        self.publish()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][:2], ("release", "upload"))
        self.assertNotIn("--clobber", self.calls[0])
        self.assertEqual(self.remote["body"], "Keep manual release notes")
        self.publish()
        self.assertEqual(len(self.calls), 1)

    def test_partial_release_uploads_only_the_missing_file(self):
        self.remote = self.release(self.assets[:1])
        self.publish()
        self.assertNotIn(str(self.assets[0]), self.calls[0])
        self.assertIn(str(self.assets[1]), self.calls[0])

    def test_identical_existing_assets_need_no_write(self):
        self.remote = self.release(self.assets)
        self.publish()
        self.assertEqual(self.calls, [])

    def test_different_digest_aborts_before_uploading_a_missing_file(self):
        self.remote = self.release(self.assets[:1])
        self.remote["assets"][0]["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(publication.PublicationError, "differs"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_different_size_aborts_without_writing(self):
        self.remote = self.release(self.assets[:1])
        self.remote["assets"][0]["size"] += 1
        with self.assertRaisesRegex(publication.PublicationError, "differs"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_legacy_assets_are_downloaded_and_compared(self):
        self.remote = self.release(self.assets)
        for item in self.remote["assets"]:
            item["digest"] = None
        self.publish()
        self.assertEqual([call[:2] for call in self.calls], [("release", "download")] * 2)

    def test_bad_legacy_bytes_are_refused(self):
        self.remote = self.release(self.assets[:1])
        self.remote["assets"][0]["digest"] = None
        def wrong_download(*args):
            (Path(args[args.index("--dir") + 1]) / self.assets[0].name).write_bytes(b"different bytes")
        with patch.object(publication, "gh", side_effect=wrong_download):
            with self.assertRaisesRegex(publication.PublicationError, "differs"):
                self.publish()

    def test_moved_tag_is_refused_before_any_mutation(self):
        self.remote_sha = "b" * 40
        with self.assertRaisesRegex(publication.PublicationError, "Remote tag differs"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_drafts_and_incomplete_or_duplicate_assets_are_refused(self):
        for change in ["draft", "state", "duplicate"]:
            with self.subTest(change=change):
                self.remote = self.release(self.assets[:1])
                if change == "draft":
                    self.remote["draft"] = True
                elif change == "state":
                    self.remote["assets"][0]["state"] = "starter"
                else:
                    self.remote["assets"].append(copy.deepcopy(self.remote["assets"][0]))
                with self.assertRaises(publication.PublicationError):
                    self.publish()
                self.assertEqual(self.calls, [])

    def test_immutable_complete_release_passes_and_missing_asset_is_refused(self):
        self.remote = self.release(self.assets)
        self.remote["immutable"] = True
        self.publish()
        self.remote["assets"].pop()
        with self.assertRaisesRegex(publication.PublicationError, "Immutable"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_create_race_and_lost_upload_response_are_reconciled(self):
        self.create_error = True
        self.publish()
        self.assertEqual(len(self.calls), 1)
        self.remote = self.release()
        self.upload_error = True
        self.publish()
        self.assertEqual(self.calls[-1][:2], ("release", "upload"))

    def test_unresolved_create_or_upload_error_is_fatal(self):
        with patch.object(publication, "gh", side_effect=publication.PublicationError("forbidden")):
            with self.assertRaisesRegex(publication.PublicationError, "forbidden"):
                self.publish()
            self.remote = self.release()
            with self.assertRaisesRegex(publication.PublicationError, "forbidden"):
                self.publish()

    def test_invalid_inputs_fail_before_network_or_writes(self):
        for repo, tag in [("owner/repo/path", self.tag), ("owner/repo", "main")]:
            with self.assertRaises(publication.PublicationError):
                publication.publish(repo, tag, self.notes, self.assets)
        self.assets[0].unlink()
        with self.assertRaises(publication.PublicationError):
            self.publish()
        self.assertEqual(self.calls, [])


class ApiTests(unittest.TestCase):
    def response(self, status, data, code=0):
        return subprocess.CompletedProcess([], code, f"HTTP/2.0 {status} Status\r\nContent-Type: application/json\r\n\r\n" + json.dumps(data), "API error" if code else "")

    def test_valid_api_and_explicit_404(self):
        with patch.object(publication, "command", return_value=self.response(200, {"id": 1})):
            self.assertEqual(publication.api("endpoint"), {"id": 1})
        with patch.object(publication, "command", return_value=self.response(404, {}, 1)):
            self.assertIsNone(publication.api("endpoint", missing_ok=True))
            with self.assertRaises(publication.PublicationError):
                publication.api("endpoint")

    def test_auth_server_and_malformed_responses_are_not_treated_as_missing(self):
        responses = [self.response(403, {}, 1), self.response(500, {}, 1), self.response(200, []),
                     subprocess.CompletedProcess([], 1, "", "network unavailable"),
                     subprocess.CompletedProcess([], 0, "HTTP/2.0 200 OK\n\ninvalid JSON", "")]
        for response in responses:
            with self.subTest(response=response):
                with patch.object(publication, "command", return_value=response):
                    with self.assertRaises(publication.PublicationError):
                        publication.api("endpoint", missing_ok=True)

    def test_timeout_is_a_publication_error(self):
        with patch.object(publication.subprocess, "run", side_effect=subprocess.TimeoutExpired("gh", 60)):
            with self.assertRaisesRegex(publication.PublicationError, "timed out"):
                publication.command(["gh", "api", "endpoint"])

    def test_cli_reports_failure_without_traceback(self):
        with patch.object(publication.sys, "argv", ["publisher", "--repo", "owner/repo", "--tag", "main",
                          "--notes-file", "notes.md", "--asset", "archive.tar.gz"]):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(publication.main(), 1)
            self.assertIn("::error::Release publication failed", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
