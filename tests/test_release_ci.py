import importlib.util
import unittest
from pathlib import Path
spec = importlib.util.spec_from_file_location("release_ci", Path(__file__).parents[1] / ".github/scripts/check-release-ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)
SHA = "a" * 40
def green():
    return dict(head_sha=SHA, event="push", head_branch="main", run_number=1,
                run_attempt=1, status="completed", conclusion="success")
class ReleaseGateTests(unittest.TestCase):
    def test_green(self):
        ci.validate_runs([green()], SHA)
    def test_missing(self):
        for data in [[], [dict(green(), head_sha="b"*40)], [dict(green(), event="pull_request")], [dict(green(), head_branch="feature")]]:
            with self.assertRaises(ValueError): ci.validate_runs(data, SHA)
    def test_incomplete_and_failed(self):
        for status, conclusion in [("queued", None), ("in_progress", None), ("completed", "failure"), ("completed", "cancelled"), ("completed", "skipped")]:
            with self.assertRaises(ValueError): ci.validate_runs([dict(green(), status=status, conclusion=conclusion)], SHA)
    def test_latest_run(self):
        with self.assertRaises(ValueError): ci.validate_runs([green(), dict(green(), run_number=2, conclusion="failure")], SHA)
        ci.validate_runs([dict(green(), conclusion="failure"), dict(green(), run_number=2)], SHA)
    def test_latest_attempt(self):
        with self.assertRaises(ValueError): ci.validate_runs([green(), dict(green(), run_attempt=2, status="in_progress")], SHA)
if __name__ == "__main__": unittest.main()

