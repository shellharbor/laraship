# LaraShip Python CLI

Install and run LaraShip through its native Bash toolkit or published Docker CLI image. The Python package uses Python 3.10+ and has no runtime Python dependencies. It preserves the existing deployment, locking, backup and recovery behavior by calling the existing tools.

The package does not install Docker, deploy an application or modify a server during `pip install`. Those operations require explicit CLI commands. Native deployments target Ubuntu 20.04+; Docker server operations target the same Linux server and its local Docker Engine. Package help and installation previews are available without root. This package does not make server deployment work directly on Windows or macOS; connect to the server over SSH.

The [complete CLI reference for 1.3.2](https://github.com/shellharbor/laraship/blob/v1.3.2/docs/CLI_REFERENCE.md) covers backend arguments, config keys, validation, presets, completion payloads and temporary Docker/Compose execution.

## Install with pip or pipx

Python packaging was introduced in 1.3.0. The commands below target release 1.3.2; a reviewed source checkout can also be installed with `pipx install .` or `python -m pip install .` inside a virtual environment. Older tags, including v1.2.2, predate Python packaging and must not be moved to publish it.

For an isolated command available on PATH, use pipx:

```bash
pipx install laraship==1.3.2
laraship --version
laraship --help
```

Alternatively, use pip in a virtual environment:

```bash
python3 -m venv "$HOME/.venvs/laraship"
"$HOME/.venvs/laraship/bin/python" -m pip install laraship==1.3.2
"$HOME/.venvs/laraship/bin/laraship" --help
```

Install the distribution-provided Python/venv or pipx packages first if these tools are missing. Keep the operating system's Python environment managed by the OS; do not use `sudo pip` or `--break-system-packages`. See the [PyPA CLI installation guide](https://packaging.python.org/en/latest/guides/installing-stand-alone-command-line-tools/).

## Native backend

Install downloads the exact GitHub release archive and SHA-256 file over HTTPS, validates the checksum and archive members, checks the embedded VERSION, then copies the complete toolkit into a new directory. Existing files, directories and symlink paths are refused. Downloads use private temporary files with size/time limits. Archive traversal, links, devices, duplicate entries and excessive expansion are rejected.

```bash
laraship install --backend native --version 1.3.2 --dry-run

# Use the absolute executable path because sudo may not include pipx in PATH.
LARASHIP_CLI="$(command -v laraship)"
sudo "$LARASHIP_CLI" install --backend native --version 1.3.2
laraship toolkit-version

sudo "$LARASHIP_CLI" deploy --backend native -- \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com
```

The default native directory is `/opt/laraship`. Use `--directory /absolute/new/path` on install and subsequent commands for another location. Its parent must exist. A partial copy caused by a disk/permission failure is retained for inspection; a rerun refuses that path. The installer does not overwrite or automatically resume it. Checksums establish consistency with GitHub's published release assets; they are not independent signatures.

The native toolkit retains its existing prerequisites and ability to install Docker when deploying. Installing the toolkit alone does not install server dependencies. See the [server requirements and deployment guide](https://github.com/shellharbor/laraship#requirements).

## Docker backend

Install Docker Engine and Compose v2 on the server and start the daemon first. This backend does not install a host daemon or run Docker-in-Docker.

```bash
laraship install --backend docker --version 1.3.2
laraship toolkit-version --backend docker --image shellharbor/laraship:1.3.2

# Informational flags go first after --; no server mounts are needed.
laraship deploy --backend docker --image shellharbor/laraship:1.3.2 -- \
  --dry-run --domain shop.example.com --db-type postgres --no-ssl

LARASHIP_CLI="$(command -v laraship)"
sudo "$LARASHIP_CLI" deploy --backend docker --image shellharbor/laraship:1.3.2 -- \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com
```

The default image is `shellharbor/laraship:<package release>`. Installing another release does not change this default; select that image with `--image` on subsequent commands. Exact version tags and SHA-256 digests are accepted; mutable aliases such as `latest` are refused. Registry version tags can still be overwritten by their owner; use a digest when immutability is required.

Server operations require root, the local `/var/run/docker.sock`, host networking and identical writable host binds for `/var/www`, `/run/lock/laraship`, the Docker socket and `/var/backups/laraship`. The three directories are created if absent after mount validation. `--archive-dir /absolute/path` changes the archive directory and its bind. Remote Docker hosts and explicit Docker contexts are refused; server commands explicitly select the local Unix socket, including when Docker has a saved default context.

Expose configuration files, SSH keys or other host inputs explicitly with repeatable `--mount-readonly /absolute/path`. The path is mounted at the same absolute location. Mounts that hide the packaged CLI or required server paths are refused:

```bash
sudo "$LARASHIP_CLI" deploy --backend docker --image shellharbor/laraship:1.3.2 \
  --mount-readonly /root/laraship-input -- \
  --config /root/laraship-input/shop.conf
```

For inspection without server-state mounts, put `--help`, `--version`, `--list-modules`, `--list-presets` or `--dry-run` first after `--` on `deploy`. The image then runs without networking, with a read-only root filesystem and writable `/tmp`; explicit `--mount-readonly` inputs remain available for configuration/hook validation. The command `toolkit-version` uses the same isolation. Ordinary server commands retain the [administrative Docker adapter's existing permissions and limitations](https://github.com/shellharbor/laraship/blob/main/docs/CONTAINERS.md); this is not an application Pod or a Kubernetes installation backend. Native host database provisioning remains unsupported by the Docker adapter.

## Commands and argument forwarding

```text
laraship --version
laraship install [--backend native|docker] [--version RELEASE] [--dry-run]
laraship toolkit-version [--backend native|docker]
laraship deploy|update|backup|activate|deactivate|remove|list [adapter options] -- [backend arguments]
```

Native is the default backend. Adapter options precede `--`; all following values are forwarded unchanged as individual arguments, without shell interpolation. Backend output, terminal input, signals and exit status go directly to/from the backend process. The Python adapter does not print the forwarded argument list. Existing backend messages and credential handling remain governed by that backend.

```bash
sudo "$LARASHIP_CLI" backup -- --slug shop now
sudo "$LARASHIP_CLI" update -- --slug shop
sudo "$LARASHIP_CLI" list --backend docker
```

CLI parsing errors exit with 2; installer/preflight errors exit with 1; cancellation during installation exits with 130. Executed backends retain their own status. The installer has no interactive prompts or implicit sudo escalation.

## Updates and removal

Use `pipx upgrade laraship` or upgrade the package with pip inside its environment. This updates the Python adapter only. It does not modify deployed projects, database volumes or an existing native toolkit directory. The Docker default follows the newly installed package version; keep `--image` explicit to retain a selected runtime.

For native toolkit upgrades, install into a new directory and select it with `--directory`. Follow the release's manual template migration and recovery guidance. Remove the Python CLI with `pipx uninstall laraship` or pip in the environment; toolkit files and deployed projects remain in place. Project deletion stays an explicit `laraship remove -- ...` operation.

## Build and verify locally

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-python-build.txt
python -m unittest discover -s tests -p 'test_python_cli.py' -v
python -m build
python -m twine check --strict dist/*
python .github/scripts/check-python-dist.py dist "$(cat VERSION)"
```

CI additionally rebuilds the wheel from the source distribution, installs with pip and pipx in fresh environments and executes the installed CLI. Backend behavior tests substitute external services; real smoke checks should distinguish package installation/command forwarding from a full Laravel deployment.

## Publish to PyPI

The existing **Release** workflow builds the Python distributions after its GitHub release and exact-commit CI gate succeed, then publishes from a separate `pypi` job with GitHub OIDC. The publish job only downloads the previously checked distributions and invokes the official PyPA action; it does not check out or execute repository build code. All new third-party action references are pinned to verified commit SHAs.

Before the first publication:

1. Create a PyPI account and configure its required account security. The name `laraship` returned HTTP 404 during the 2026-10-22 check; this does not reserve the name or guarantee PyPI will allow it.
2. In [PyPI pending publishers](https://pypi.org/manage/account/publishing/), add project **laraship**, GitHub owner **shellharbor**, repository **laraship**, workflow **release.yml**, and environment **pypi**. For an existing project, add the same Trusted Publisher under its publishing settings.
3. Create GitHub environment **pypi**. Restrict it to release tags and the default branch used for manual release retries; configure required reviewers if desired.
4. Set GitHub Actions repository **Variable** `PYPI_PUBLISH=true`. No PyPI token Secret is used. If this variable is absent, existing GitHub and Docker Hub publication behave as before and the Python publishing jobs skip.
5. Commit the feature, prepare a **new release version** in VERSION/CHANGELOG, push it and wait for all required checks on that exact commit. Tests includes the Python package matrix. Tag the verified commit using the existing release process.

For a failed publication, rerun the failed jobs. You can also dispatch **Release** for the existing new tag after fixing configuration. PyPI refuses replacement of published distribution filenames; successful files may be skipped by the publish action on retries. Do not change source code or move an existing tag to repair a published package. A code fix requires a new version.

VERSION is the single version source for Bash, archives and the Python package. Python distribution filenames normalize prerelease versions according to PEP 440; metadata versions are compared by their PEP 440 identity. The wheel also records the exact original release spelling for GitHub asset names and Docker defaults. Existing tags without pyproject.toml cannot publish a Python package. Enabling this workflow and preparing files do not publish anything until the repository and PyPI settings are configured and a suitable release is run.

References: [PyPA packaging guide](https://packaging.python.org/en/latest/guides/writing-pyproject-toml/), [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/using-a-publisher/), [publisher action](https://github.com/pypa/gh-action-pypi-publish).
