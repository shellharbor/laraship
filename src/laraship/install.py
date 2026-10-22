"""Download, verify and install an explicit official LaraShip release."""

import hashlib
import gzip
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, build_opener

MAX_DOWNLOAD = 64 * 1024 * 1024
MAX_EXPANDED = 128 * 1024 * 1024
MAX_MEMBERS = 20000
RELEASE_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?"
REQUIRED_FILES = ("VERSION", "versions.env", "deploy-laravel.sh", "update.sh",
                  "backup.sh", "activate.sh", "deactivate.sh", "remove.sh",
                  "list-projects.sh", "lib/runtime.sh", "laravel/docker-compose.yml",
                  "nginxproxy/nginx.conf")


def release_version(value: str) -> str:
    """Accept release filenames, without path components or mutable aliases."""
    if not re.fullmatch(RELEASE_PATTERN, value):
        raise ValueError("Use an exact release version, for example 1.2.2 or 1.3.0-rc.1")
    return value


def absolute_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute() or ".." in path.parts or any(c in str(path) for c in "\x00\r\n,"):
        raise ValueError("Use an absolute path without '..', commas or control characters")
    return path


def installation_path(value: str) -> Path:
    destination = absolute_path(value)
    for path in (destination, *destination.parents):
        if path.is_symlink():
            raise ValueError("Installation paths must not contain symbolic links")
    if destination.exists():
        raise ValueError("Installation path already exists; choose a new directory with --directory")
    if not destination.parent.is_dir():
        raise ValueError("Installation parent directory must already exist")
    return destination


class HTTPSRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise ValueError("Refusing a download redirect without HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, destination: Path, limit: int = MAX_DOWNLOAD) -> None:
    """Bound network operations and stream into an exclusively created private file."""
    if urlsplit(url).scheme != "https":
        raise ValueError("Release downloads require HTTPS")
    started = time.monotonic()
    opener = build_opener(HTTPSRedirects())
    with opener.open(url, timeout=30) as response:
        with destination.open("xb") as output:
            os.chmod(destination, 0o600)
            total = 0
            while chunk := response.read(65536):
                total += len(chunk)
                if total > limit or time.monotonic() - started > 180:
                    raise ValueError("Release download exceeded its size or time limit")
                output.write(chunk)


def verify_checksum(archive: Path, checksum: Path, filename: str) -> None:
    text = checksum.read_text(encoding="ascii").strip()
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]" + re.escape(filename), text)
    if not match:
        raise ValueError("Checksum file must contain exactly the requested archive name and SHA-256")
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    if digest.hexdigest() != match[1].lower():
        raise ValueError("Release archive SHA-256 does not match; nothing was installed")


def unpack_release(archive: Path, staging: Path, version: str) -> Path:
    """Extract regular files only; never follow archive links or traversal paths."""
    prefix = f"laraship-{release_version(version)}"
    staging.mkdir(mode=0o700, parents=True)
    unpacked_tar = staging / "release.tar"
    expanded = 0
    # Bound the complete tar stream, including PAX/GNU headers, before parsing it.
    with gzip.open(archive, "rb") as compressed, unpacked_tar.open("xb") as output:
        while chunk := compressed.read(65536):
            expanded += len(chunk)
            if expanded > MAX_EXPANDED:
                raise ValueError("Expanded release archive exceeds the size limit")
            output.write(chunk)
    seen: set[str] = set()
    total = 0
    with tarfile.open(unpacked_tar, "r:") as source:
        for count, member in enumerate(source, 1):
            path = PurePosixPath(member.name)
            parts = path.parts
            if (count > MAX_MEMBERS or path.is_absolute() or not parts or parts[0] != prefix
                    or ".." in parts or "\\" in member.name
                    or any(ord(c) < 32 for c in member.name)
                    or not (member.isdir() or member.isfile()) or member.name in seen):
                raise ValueError("Release archive contains an unsafe or duplicate entry")
            seen.add(member.name)
            total += member.size
            if member.size < 0 or total > MAX_EXPANDED:
                raise ValueError("Expanded release archive exceeds the size limit")
            target = staging.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            reader = source.extractfile(member)
            if reader is None:
                raise ValueError("Release archive contains an unreadable file")
            with reader, target.open("xb") as output:
                shutil.copyfileobj(reader, output)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    root = staging / prefix
    if any(not (root / name).is_file() for name in REQUIRED_FILES):
        raise ValueError("Release archive is missing required LaraShip files")
    if (root / "VERSION").read_text(encoding="ascii").strip() != version:
        raise ValueError("Release archive VERSION does not match the requested release")
    if (root / ".laraship-installing").exists():
        raise ValueError("Release archive contains a reserved installation marker")
    # A permissive caller umask must not make the installed root-run toolkit writable.
    root.chmod(0o755)
    for path in root.rglob("*"):
        if path.is_dir():
            path.chmod(0o755)
    return root


def install_native(version: str, directory: str) -> Path:
    version = release_version(version)
    destination = installation_path(directory)
    filename = f"laraship-{version}.tar.gz"
    base = f"https://github.com/shellharbor/laraship/releases/download/v{version}"
    with tempfile.TemporaryDirectory(prefix="laraship-install-") as temporary:
        private = Path(temporary)
        archive = private / filename
        checksum = private / f"{filename}.sha256"
        download(f"{base}/{filename}.sha256", checksum, limit=4096)
        download(f"{base}/{filename}", archive)
        verify_checksum(archive, checksum, filename)
        staged = unpack_release(archive, private / "unpacked", version)
        # Reserve exclusively, including in a concurrent install. Failed copies stay
        # visible and marked for inspection; they are never removed or overwritten.
        destination.mkdir(mode=0o755)
        marker = destination / ".laraship-installing"
        marker.write_text("Installation incomplete; inspect this directory before use.\n", encoding="ascii")
        marker.chmod(0o600)
        shutil.copytree(staged, destination, dirs_exist_ok=True)
        marker.unlink()
    return destination
