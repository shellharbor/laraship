#!/usr/bin/env python3
"""Validate release identity and the explicit Python distribution file allowlist."""

import argparse
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
import tarfile
import zipfile

from packaging.version import Version

SOURCE_FILES = {"src/laraship/__init__.py", "src/laraship/__main__.py",
                "src/laraship/cli.py", "src/laraship/install.py"}


def check(directory: Path, release: str) -> None:
    wheels = list(directory.glob("*.whl"))
    sources = list(directory.glob("*.tar.gz"))
    if len(wheels) != 1 or len(sources) != 1 or len(list(directory.iterdir())) != 2:
        raise ValueError("Expected exactly one wheel and one source distribution")
    expected_version = str(Version(release))
    with zipfile.ZipFile(wheels[0]) as wheel:
        runtime = {name.removeprefix("src/") for name in SOURCE_FILES} | {"laraship/_release.txt"}
        metadata_prefix = f"laraship-{expected_version}.dist-info/"
        metadata_files = {metadata_prefix + name for name in ("METADATA", "WHEEL", "entry_points.txt", "RECORD")}
        if set(wheel.namelist()) != runtime | metadata_files:
            raise ValueError("Wheel contains unexpected or missing files")
        metadata = BytesParser().parsebytes(wheel.read(metadata_prefix + "METADATA"))
        if (metadata["Name"] != "laraship" or not metadata["Version"]
                or Version(metadata["Version"]) != Version(release)):
            raise ValueError("Wheel metadata does not match the release")
        if metadata.get_all("Requires-Dist"):
            raise ValueError("The runtime package must remain dependency-free")
        if wheel.read("laraship/_release.txt").decode("ascii").strip() != release:
            raise ValueError("Wheel toolkit default differs from the release")
        if "laraship = laraship.cli:main" not in wheel.read(metadata_prefix + "entry_points.txt").decode():
            raise ValueError("Wheel is missing the laraship console command")
    allowed = SOURCE_FILES | {"VERSION", "pyproject.toml", "docs/PYTHON.md", "PKG-INFO", ".gitignore"}
    with tarfile.open(sources[0], "r:gz") as source:
        prefix = f"laraship-{expected_version}"
        files = set()
        for member in source:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or path.parts[0] != prefix:
                raise ValueError("Unsafe source distribution path")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("Source distribution links and special files are forbidden")
            files.add(str(PurePosixPath(*path.parts[1:])))
        if files != allowed:
            raise ValueError("Source distribution contains unexpected or missing files")
    print(f"Python distributions verified for {release}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("release")
    args = parser.parse_args()
    check(args.directory, args.release)
