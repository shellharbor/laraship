#!/usr/bin/env bash
# Run the tests locally in an isolated sandbox (only Docker is needed).
#
#   bash tests/run-local.sh            # unit: shellcheck + static, validation, presets and safety
#   bash tests/run-local.sh e2e        # real Laravel deployment (PostgreSQL + Filament)
#   bash tests/run-local.sh container  # actual CLI image and native Bash interoperability
#   bash tests/run-local.sh kubernetes # real Laravel on disposable kind
#   bash tests/run-local.sh e2e-proxy  # shared proxy with two real sites and TLS
#   bash tests/run-local.sh e2e-db-migration # legacy dumps into Docker Official Images
#   bash tests/run-local.sh e2e-repo   # deploy an existing app with --repo, then update.sh
#   bash tests/run-local.sh e2e-modules # --with filament,horizon
#   E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e
#   E2E_DB=mysql bash tests/run-local.sh e2e-db-migration
#   bash tests/run-local.sh install                     # the install matrix: every case (long)
#   bash tests/run-local.sh install laravel10-postgres native-mysql   # chosen cases only
#   bash tests/run-local.sh all
#   bash tests/run-local.sh full       # both databases, Laravel/Filament, extras, modules, repos, install matrix
#
# The sandbox runs with --privileged and its own Docker daemon: containers, networks
# and ports 80/443 are created inside it, the host's Docker is not affected. The image
# cache lives in the laraship-tests-docker volume (remove it with:
# docker volume rm laraship-tests-docker).
set -euo pipefail

MODE="${1:-unit}"
shift || true
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Git Bash on Windows: keep MSYS from rewriting paths and use the Windows path for -v.
export MSYS_NO_PATHCONV=1
MOUNT="${ROOT}"
EXTRA_DOCKER_ARGS=()
if [[ "$MODE" == kubernetes ]]; then
    # Nested systemd needs the real cgroup hierarchy; no host Docker socket is mounted.
    EXTRA_DOCKER_ARGS+=(--cgroupns=host)
fi
if command -v cygpath >/dev/null 2>&1; then
    MOUNT="$(cygpath -w "${ROOT}")"
fi
if [[ "$MODE" = full ]]; then
    RESULTS_DIR="${LARASHIP_TEST_RESULTS:-$ROOT/tmp/test-results/$(date -u +%Y%m%d-%H%M%S)-$$}"
    if [[ -L "$RESULTS_DIR" || ( -e "$RESULTS_DIR" && ! -d "$RESULTS_DIR" ) ]]; then
        echo "Full matrix results require an empty real directory: $RESULTS_DIR" >&2; exit 1
    fi
    if [[ -d "$RESULTS_DIR" && -n "$(find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "Full matrix results require an empty real directory: $RESULTS_DIR" >&2; exit 1
    fi
    (umask 077; mkdir -p "$RESULTS_DIR")
    chmod 700 "$RESULTS_DIR"
    RESULTS_MOUNT="$RESULTS_DIR"
    if command -v cygpath >/dev/null 2>&1; then RESULTS_MOUNT="$(cygpath -w "$RESULTS_DIR")"; fi
    EXTRA_DOCKER_ARGS=(-v "$RESULTS_MOUNT:/results" -e FULL_RESULTS_DIR=/results -e "RESULTS_UID=$(id -u)" -e "RESULTS_GID=$(id -g)")
    echo "Full matrix results: $RESULTS_DIR"
fi

docker build -q -t laraship-tests -f "${MOUNT}/tests/Dockerfile" "${MOUNT}" >/dev/null

docker run --rm --privileged \
    "${EXTRA_DOCKER_ARGS[@]}" \
    -v "${MOUNT}:/repo:ro" \
    -v laraship-tests-docker:/var/lib/docker \
    -e E2E_DB="${E2E_DB:-postgres}" \
    -e E2E_FILAMENT="${E2E_FILAMENT:-1}" \
    -e E2E_LARAVEL="${E2E_LARAVEL:-}" \
    -e E2E_SSL="${E2E_SSL:-0}" \
    -e E2E_EXTRAS="${E2E_EXTRAS:-0}" \
    -e E2E_CONFIG="${E2E_CONFIG:-0}" \
    -e K8S_LARAVEL="${K8S_LARAVEL:-13.0.0}" \
    -e FULL_PHASE="${FULL_PHASE:-all}" \
    -e FULL_SCENARIOS="${FULL_SCENARIOS:-}" \
    laraship-tests "${MODE}" "$@"
