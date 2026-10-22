"""LaraShip's dependency-free installation and execution adapter."""

from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

_release_file = Path(__file__).with_name("_release.txt")
if not _release_file.is_file():
    _release_file = Path(__file__).resolve().parents[2] / "VERSION"
DEFAULT_RELEASE = _release_file.read_text(encoding="ascii").strip()

try:
    __version__ = version("laraship")
except PackageNotFoundError:
    __version__ = DEFAULT_RELEASE
