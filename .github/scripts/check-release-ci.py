#!/usr/bin/env python3
"""Refuse publication unless every required workflow passed for the checked-out commit."""
import json
import os
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REQUIRED = ("lint.yml", "tests.yml", "e2e.yml", "codeql.yml", "kubernetes.yml")


def validate_runs(runs: list, sha: str) -> None:
    eligible = [run for run in runs if run.get("head_sha") == sha
                and run.get("event") == "push" and run.get("head_branch") in ("main", "master")]
    if not eligible:
        raise ValueError("No main/master push run exists for this commit")
    latest = max(eligible, key=lambda run: (run["run_number"], run.get("run_attempt", 1)))
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("The latest run is not completed successfully")


def main() -> int:
    try:
        repo = os.environ["GITHUB_REPOSITORY"]
        token = os.environ["GH_TOKEN"]
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid repository name")
        if not re.fullmatch(r"[0-9a-f]{40,64}", sha):
            raise ValueError("Invalid commit hash")
        base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        for workflow in REQUIRED:
            url = f"{base}/repos/{repo}/actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"
            request = Request(url, headers={"Authorization": f"Bearer {token}",
                                           "Accept": "application/vnd.github+json",
                                           "X-GitHub-Api-Version": "2022-11-28"})
            with urlopen(request, timeout=15) as response:
                runs = json.load(response)["workflow_runs"]
            try:
                validate_runs(runs, sha)
            except ValueError as exc:
                raise ValueError(f"{workflow}: {exc}") from exc
            print(f"{workflow}: successful for {sha}")
    except (KeyError, ValueError, HTTPError, URLError, OSError) as exc:
        print(f"::error::Release CI gate failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
