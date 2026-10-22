# ADR-0008: Distribute a Python adapter for native and Docker operations

- Date: 2026-10-22
- Status: accepted, unreleased

## Context

LaraShip already has Bash deployment/lifecycle tools, versioned GitHub release archives with SHA-256 files and a Docker CLI image. The user requested installation through pip/pipx with both native and Docker backends and a PyPI publication workflow. Reimplementing deployment would duplicate sensitive database, lock, proxy and recovery behavior.

## Options

- Keep manual archive/image installation only.
- Add a standalone downloader script without package management.
- Package a thin Python installer/runner while retaining existing deployment engines.
- Reimplement deployment in Python and maintain a separate runtime contract.

## Decision

Publish the dependency-free `laraship` Python CLI for Python 3.10+. Use VERSION as the build version source; retain its exact release spelling in the wheel to address prerelease archives/images after PEP 440 metadata normalization. Explicit source/wheel allowlists exclude templates, secrets, AI-KIT, tests and repository history from Python distributions. The native toolkit is downloaded separately from an exact official release with HTTPS, checksum checks, bounded extraction and exclusive destination creation. Existing destinations are refused; failed copies retain an incomplete marker and are not run.

Commands call the existing Bash tools or Docker CLI image with an argument list and process replacement. Native is the default. Docker server operations retain the administrative adapter's justified local-socket, root, host-network and identical-bind exceptions from ADR-0005. No new daemon, application container, microservice or Kubernetes workload is introduced. Informational Docker commands run without server mounts or networking and with a read-only root filesystem. The Python package is not a Kubernetes deployment backend.

Keep pip/pipx installation separate from host provisioning and application deployment. Updating/removing the package does not update/remove existing projects or native toolkit directories. Docker defaults follow the installed package version; explicit image references preserve the selected runtime.

Extend the Tests workflow with package build/install checks, preserving its existing inclusion in the exact-commit release gate. Add optional Python build and publish jobs to the existing Release workflow, enabled by PYPI_PUBLISH=true. This avoids relying on a separate release-event workflow: releases created with GitHub's built-in workflow token do not trigger another ordinary release-event workflow. Use top-level OIDC publishing with environment pypi because PyPI does not support a reusable workflow as a Trusted Publisher. Keep build code and package validation in a job without id-token permission; the separate publisher downloads the immutable artifact by its job output ID, including failed-job retries, and publishes with the official SHA-pinned PyPA action.

## Consequences and verification

Maintainers must configure the PyPI project/pending publisher and GitHub environment/Variable before publication. No API token is needed. Existing tags without packaging are not repurposed; a new release is required. PyPI name availability is not ownership or reservation. The repository has no verified project license, so packaging does not invent a license grant.

Installer tests cover checksum/path/archive failures, concurrent/rerun behavior, incomplete copies, argument privacy and daemon/mount checks. CI builds wheel/sdist, verifies exact contents and versions, installs via pip and pipx, and checks Python 3.10/3.12/3.14. Real smoke evidence must distinguish adapter operation from full Laravel deployment. See [Python operations](../PYTHON.md) and [tests](../../tests/test_python_cli.py).

References: [PyPA CLI packaging](https://packaging.python.org/en/latest/guides/creating-command-line-tools/), [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/using-a-publisher/), [PyPI reusable-workflow limitation](https://docs.pypi.org/trusted-publishers/troubleshooting/), [GitHub workflow token event behavior](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow).
