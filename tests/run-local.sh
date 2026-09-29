#!/usr/bin/env bash
# Run the tests locally in an isolated sandbox (only Docker is needed).
#
#   bash tests/run-local.sh            # unit: shellcheck + static checks + argument validation
#   bash tests/run-local.sh e2e        # real Laravel deployment (PostgreSQL + Filament)
#   E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e
#   bash tests/run-local.sh all
#
# The sandbox runs with --privileged and its own Docker daemon: containers, networks
# and ports 80/443 are created inside it, the host's Docker is not affected. The image
# cache lives in the laravel-deploy-tests-docker volume (remove it with:
# docker volume rm laravel-deploy-tests-docker).
set -euo pipefail

MODE="${1:-unit}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Git Bash on Windows: keep MSYS from rewriting paths and use the Windows path for -v.
export MSYS_NO_PATHCONV=1
MOUNT="${ROOT}"
if command -v cygpath >/dev/null 2>&1; then
    MOUNT="$(cygpath -w "${ROOT}")"
fi

docker build -q -t laravel-deploy-tests -f "${MOUNT}/tests/Dockerfile" "${MOUNT}" >/dev/null

docker run --rm --privileged \
    -v "${MOUNT}:/repo:ro" \
    -v laravel-deploy-tests-docker:/var/lib/docker \
    -e E2E_DB="${E2E_DB:-postgres}" \
    -e E2E_FILAMENT="${E2E_FILAMENT:-1}" \
    -e E2E_LARAVEL="${E2E_LARAVEL:-}" \
    -e E2E_SSL="${E2E_SSL:-0}" \
    laravel-deploy-tests "${MODE}"
