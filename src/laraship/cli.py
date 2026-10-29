"""Install LaraShip and forward commands to its existing execution backends."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from urllib.error import URLError

from . import DEFAULT_RELEASE, __version__
from .install import absolute_path, install_native, installation_path, release_version

COMMANDS = {"deploy": "deploy-laravel.sh", "update": "update.sh", "upgrade": "upgrade.sh", "backup": "backup.sh",
            "activate": "activate.sh", "deactivate": "deactivate.sh", "remove": "remove.sh",
            "list": "list-projects.sh", "toolkit-version": "deploy-laravel.sh"}
SERVER_PATHS = ("/var/www", "/run/lock/laraship", "/var/run/docker.sock")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--version", action="version", version=f"laraship {__version__}")
    commands = result.add_subparsers(dest="command", required=True)
    install = commands.add_parser("install", help="Install a release or pull its CLI image")
    install.add_argument("--backend", choices=("native", "docker"), default="native")
    install.add_argument("--version", dest="release", help="Exact toolkit release (defaults to the package version)")
    install.add_argument("--directory", default="/opt/laraship", help="New native toolkit directory")
    install.add_argument("--dry-run", action="store_true", help="Show the plan without network requests or writes")
    for name in COMMANDS:
        command = commands.add_parser(name, help=f"Run the existing {name} command")
        command.add_argument("--backend", choices=("native", "docker"), default="native")
        command.add_argument("--directory", default="/opt/laraship", help="Installed native toolkit directory")
        command.add_argument("--image", help="Docker image with an exact release tag or SHA-256 digest")
        command.add_argument("--archive-dir", default="/var/backups/laraship")
        command.add_argument("--mount-readonly", action="append", default=[], metavar="ABSOLUTE_PATH",
                             help="Expose an extra host file/directory at the same path in Docker")
        command.add_argument("arguments", nargs=argparse.REMAINDER,
                             help="Separate all backend arguments with --")
    return result


def image_reference(value: str) -> str:
    repository = r"(?:[a-z0-9]+(?:[._-][a-z0-9]+)*/)*[a-z0-9]+(?:[._-][a-z0-9]+)*"
    if re.fullmatch(repository + r"@sha256:[0-9a-f]{64}", value):
        return value
    if ":" not in value:
        raise ValueError("Docker images require an exact release tag or SHA-256 digest")
    name, tag = value.rsplit(":", 1)
    if not re.fullmatch(repository, name):
        raise ValueError("Invalid Docker image repository")
    release_version(tag)
    return value


def require_linux() -> None:
    if sys.platform != "linux":
        raise ValueError("Run installation and server operations on the target Linux server over SSH")


def require_docker(local: bool = False) -> None:
    if not shutil.which("docker"):
        raise ValueError("Docker is not installed; install Docker Engine and Compose v2 on the server first")
    try:
        command = ["docker", "--host", "unix:///var/run/docker.sock"] if local else ["docker"]
        probe = subprocess.run([*command, "info", "--format", "{{.OSType}}"],
                               capture_output=True, text=True, timeout=15, check=False)
    except subprocess.TimeoutExpired as exc:
        raise ValueError("Docker daemon check timed out") from exc
    if probe.returncode or probe.stdout.strip() != "linux":
        raise ValueError("A running Linux Docker daemon accessible to this user is required")


def informational(command: str, arguments: list[str]) -> bool:
    if command == "toolkit-version" or arguments == ["--help"]:
        return True
    if command == "upgrade" and arguments in (["-h"], ["--version"]):
        return True
    return command == "deploy" and bool(arguments) and arguments[0] in (
        "--dry-run", "--help", "-h", "--version", "-V", "--list-modules", "--list-presets")


def upgrade_preview(command: str, arguments: list[str]) -> bool:
    return command == "upgrade" and not any(
        value.split("=", 1)[0] in ("--prepare", "--verify", "--apply", "--recover") for value in arguments)


def docker_command(args: argparse.Namespace, arguments: list[str]) -> list[str]:
    image = image_reference(args.image or f"shellharbor/laraship:{release_version(DEFAULT_RELEASE)}")
    command = ["docker", "run", "--rm", "--init"]
    if informational(args.command, arguments):
        command += ["--network", "none", "--read-only", "--tmpfs", "/tmp"]
    else:
        require_linux()
        if os.geteuid() != 0:
            raise ValueError("Docker server operations require root; use sudo with the absolute CLI path")
        if os.environ.get("DOCKER_HOST", "unix:///var/run/docker.sock") != "unix:///var/run/docker.sock":
            raise ValueError("Server operations require the local /var/run/docker.sock daemon")
        if os.environ.get("DOCKER_CONTEXT"):
            raise ValueError("Unset DOCKER_CONTEXT; server operations require the local Docker daemon")
        archive = absolute_path(args.archive_dir)
        preview = upgrade_preview(args.command, arguments)
        paths = ("/var/www", "/var/run/docker.sock") if preview else (*SERVER_PATHS, str(archive))
        protected_archives = (*SERVER_PATHS, "/opt/laraship", "/usr", "/bin", "/etc")
        if any(archive == Path(p) or archive in Path(p).parents or Path(p) in archive.parents
               for p in protected_archives):
            raise ValueError("Archive directory must be separate from server mounts and runtime paths")
        for value in paths:
            path = absolute_path(value)
            if any(part.is_symlink() and not (part == Path("/var/run") and part.resolve() == Path("/run"))
                   for part in (path, *path.parents)):
                raise ValueError("Docker server mount paths must not contain symbolic links")
        if not Path("/var/run/docker.sock").exists():
            raise ValueError("The local /var/run/docker.sock is missing")
        # Ignore the user's saved default Docker context for host-mutating operations.
        command[1:1] = ["--host", "unix:///var/run/docker.sock"]
        command += ["--interactive"]
        if sys.stdin.isatty() and sys.stdout.isatty():
            command += ["--tty"]
        command += ["--network", "host"]
        if preview:
            command += ["--read-only", "--tmpfs", "/tmp"]
        else:
            command += ["--env", f"LARASHIP_ARCHIVE_DIR={archive}"]
        for value in paths:
            command += ["--mount", f"type=bind,src={value},dst={value}" + (",readonly" if preview else "")]
    if args.mount_readonly:
        require_linux()
        protected = (*SERVER_PATHS, str(absolute_path(args.archive_dir)), "/opt/laraship", "/usr", "/bin", "/etc")
        for value in args.mount_readonly:
            path = absolute_path(value)
            if not path.exists() or any(path == Path(p) or path in Path(p).parents for p in protected):
                raise ValueError("Additional read-only mount is missing or shadows a protected path")
            command += ["--mount", f"type=bind,src={path},dst={path},readonly"]
    backend = "--version" if args.command == "toolkit-version" else args.command
    return [*command, image, backend, *arguments]


def native_command(args: argparse.Namespace, arguments: list[str]) -> list[str]:
    require_linux()
    root = absolute_path(args.directory)
    if (root / ".laraship-installing").exists():
        raise ValueError("Native toolkit installation is incomplete; inspect it before use")
    if not (root / "VERSION").is_file() or not (root / COMMANDS[args.command]).is_file():
        raise ValueError("Native toolkit is missing; run 'laraship install' or select --directory")
    if not shutil.which("bash"):
        raise ValueError("Bash is required for the native backend")
    backend_args = ["--version"] if args.command == "toolkit-version" else arguments
    return ["bash", str(root / COMMANDS[args.command]), *backend_args]


def execute(command: list[str]) -> int:
    """Replace the adapter so the backend receives signals, terminal I/O and exit status."""
    os.execvp(command[0], command)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "install":
            version = release_version(args.release or DEFAULT_RELEASE)
            if args.backend == "native":
                destination = installation_path(args.directory)
                if args.dry_run:
                    print(f"Would download and verify LaraShip {version}, then install into {destination}")
                    return 0
                require_linux()
                install_native(version, str(destination))
                print(f"Installed LaraShip {version} into {destination}")
            else:
                image = f"shellharbor/laraship:{version}"
                if args.dry_run:
                    print(f"Would pull {image}; no deployment or host setup would run")
                    return 0
                require_linux()
                require_docker()
                result = subprocess.run(["docker", "pull", image], check=False)
                if result.returncode:
                    return result.returncode
                print(f"Pulled {image}; select --backend docker when running commands")
            return 0
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        if args.command == "toolkit-version" and arguments:
            raise ValueError("toolkit-version does not accept backend arguments")
        if args.backend == "docker":
            # Reject invalid references before contacting Docker or changing host paths.
            if args.image:
                image_reference(args.image)
            command = docker_command(args, arguments)
            inspect_only = informational(args.command, arguments)
            require_docker(local=not inspect_only)
            if not inspect_only and not upgrade_preview(args.command, arguments):
                # All arguments, mounts and the local daemon were checked before writes.
                for value in ("/var/www", "/run/lock/laraship", args.archive_dir):
                    absolute_path(value).mkdir(parents=True, exist_ok=True)
        else:
            if args.image or args.mount_readonly:
                raise ValueError("--image and --mount-readonly require --backend docker")
            command = native_command(args, arguments)
        return execute(command)
    except KeyboardInterrupt:
        print("LaraShip operation cancelled", file=sys.stderr)
        return 130
    except (ValueError, OSError, URLError, tarfile.TarError, shutil.Error) as exc:
        # Backend commands inherit stdout/stderr; never stringify their argument lists.
        print(f"LaraShip: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
