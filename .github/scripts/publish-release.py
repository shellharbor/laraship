#!/usr/bin/env python3
"""Create a release or reconcile its assets without overwriting published files."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote


class PublicationError(RuntimeError):
    pass


def command(args: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(args, text=True, encoding="utf-8", capture_output=True, timeout=60, check=False)
    except subprocess.TimeoutExpired as exc:
        raise PublicationError(f"{args[0]} operation timed out") from exc


def gh(*args: str) -> str:
    result = command(["gh", *args])
    if result.returncode:
        raise PublicationError(result.stderr.strip() or "GitHub CLI operation failed")
    return result.stdout


def api(endpoint: str, *, missing_ok: bool = False) -> dict | None:
    result = command(["gh", "api", "--include", "--method", "GET", endpoint])
    response = result.stdout.replace("\r\n", "\n")
    headers, separator, body = response.partition("\n\n")
    match = re.search(r"^HTTP/[0-9.]+\s+(\d{3})\b", headers, re.MULTILINE)
    status = int(match[1]) if match else None
    if status == 404 and missing_ok:
        return None
    if result.returncode or status != 200 or not separator:
        raise PublicationError(f"GitHub API inspection failed ({status or 'CLI error'}): {result.stderr.strip()}")
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise PublicationError("GitHub API returned invalid JSON") from exc
    if not isinstance(data, dict):
        raise PublicationError("GitHub API returned an unexpected response")
    return data


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return "sha256:" + checksum.hexdigest()


def verify_existing(release: dict, repo: str, tag: str, assets: list[Path]) -> list[Path]:
    if release.get("tag_name") != tag or release.get("draft") is not False:
        raise PublicationError("Existing release has a different tag or is a draft; inspect it before publication")
    records = release.get("assets")
    if not isinstance(records, list) or any(not isinstance(item, dict) for item in records):
        raise PublicationError("Existing release has an invalid asset list")
    missing = []
    # Validate every existing expected asset before uploading any missing file.
    for path in assets:
        matches = [item for item in records if item.get("name") == path.name]
        if not matches:
            missing.append(path)
            continue
        if len(matches) != 1 or matches[0].get("state") != "uploaded":
            raise PublicationError(f"Asset {path.name} is duplicated or incomplete; inspect it before publication")
        item = matches[0]
        if item.get("size") != path.stat().st_size:
            raise PublicationError(f"Existing asset {path.name} differs; use a new version instead of overwriting it")
        remote_digest = item.get("digest")
        if not remote_digest:
            # Older GitHub assets may lack digest metadata. Compare the downloaded bytes.
            with tempfile.TemporaryDirectory(prefix="laraship-release-") as directory:
                gh("release", "download", tag, "--repo", repo, "--pattern", path.name, "--dir", directory)
                remote_digest = digest(Path(directory) / path.name)
        if remote_digest != digest(path):
            raise PublicationError(f"Existing asset {path.name} differs; use a new version instead of overwriting it")
    if missing and release.get("immutable"):
        raise PublicationError("Immutable release is missing expected assets; use a new version")
    return missing


def publish(repo: str, tag: str, notes: Path, assets: list[Path]) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise PublicationError("Invalid repository name")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?", tag):
        raise PublicationError("Invalid release tag")
    if not notes.is_file() or not assets or any(not path.is_file() for path in assets):
        raise PublicationError("Release notes and all assets must exist before publication")
    if len({path.name for path in assets}) != len(assets) or any(
            not re.fullmatch(r"[A-Za-z0-9_.-]+", path.name) for path in assets):
        raise PublicationError("Asset names must be unique and contain only letters, digits, dots, underscores and hyphens")
    head = command(["git", "rev-parse", "HEAD"])
    if head.returncode or not re.fullmatch(r"[0-9a-f]{40,64}", head.stdout.strip()):
        raise PublicationError("Cannot identify the checked-out release commit")
    remote_commit = api(f"repos/{repo}/commits/{quote(tag, safe='')}")
    if remote_commit.get("sha") != head.stdout.strip():
        raise PublicationError("Remote tag differs from the checked-out commit; publication refused")
    endpoint = f"repos/{repo}/releases/tags/{quote(tag, safe='')}"
    release = api(endpoint, missing_ok=True)
    if release is None:
        args = ["release", "create", tag, *(str(path.absolute()) for path in assets), "--repo", repo,
                "--title", tag[1:], "--notes-file", str(notes.absolute()), "--verify-tag"]
        if "-" in tag:
            args.append("--prerelease")
        try:
            gh(*args)
        except PublicationError:
            # Creation may have raced with another publisher or succeeded before a timeout.
            release = api(endpoint, missing_ok=True)
            if release is None:
                raise
        else:
            print(f"Release {tag} created with its assets")
            return
    missing = verify_existing(release, repo, tag, assets)
    if missing:
        try:
            gh("release", "upload", tag, *(str(path.absolute()) for path in missing), "--repo", repo)
        except PublicationError:
            # A completed upload or concurrent publisher can make an otherwise failed retry complete.
            release = api(endpoint)
            if verify_existing(release, repo, tag, assets):
                raise
        else:
            release = api(endpoint)
            if verify_existing(release, repo, tag, assets):
                raise PublicationError("Release upload completed but expected assets are still missing")
    print(f"Release {tag} verified; existing metadata and assets preserved")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"), required=not os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--notes-file", type=Path, required=True)
    parser.add_argument("--asset", type=Path, action="append", required=True)
    args = parser.parse_args()
    try:
        publish(args.repo, args.tag, args.notes_file, args.asset)
    except (PublicationError, OSError) as exc:
        print(f"::error::Release publication failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
