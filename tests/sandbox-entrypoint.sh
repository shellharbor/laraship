#!/usr/bin/env bash
# Sandbox entrypoint: starts the inner dockerd, copies the repository and runs the
# selected test suite.
#   unit  - shellcheck + static.bats + validation.bats (fast, no Docker deployment)
#   e2e   - real deployment and lifecycle (slow, pulls images)
#   all   - unit, then e2e
set -euo pipefail

MODE="${1:-unit}"
SRC=/repo
WORK=/opt/laravel-deploy

start_dockerd() {
    dockerd >/var/log/dockerd.log 2>&1 &
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "dockerd did not start:" >&2
    tail -n 30 /var/log/dockerd.log >&2
    exit 1
}

# The cache volume keeps containers from earlier runs (nginxproxy with restart: always).
# When the daemon starts they come back to life and create empty bind-mount
# directories in /var/www, which makes the script skip the nginxproxy initialization.
# Start from a clean slate, keeping only the images (the build cache).
reset_state() {
    docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker volume prune -af >/dev/null 2>&1 || true
    rm -rf /var/www
}

run_unit() {
    echo "==> shellcheck"
    # SC2155 (declare and assign separately) is a style issue in remove.sh: known and excluded.
    (cd "${WORK}" && shellcheck -S warning -e SC2155 deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh)
    echo "==> bats: static + validation"
    bats --print-output-on-failure "${WORK}/tests/static.bats" "${WORK}/tests/validation.bats"
}

run_e2e() {
    echo "==> bats: e2e (db=${E2E_DB:-postgres}, filament=${E2E_FILAMENT:-1}, laravel=${E2E_LARAVEL:-default})"
    E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e.bats"
}

cp -r "${SRC}" "${WORK}"
find "${WORK}" -name '*.sh' -exec chmod +x {} +
start_dockerd
reset_state

case "${MODE}" in
    unit) run_unit ;;
    e2e)  run_e2e ;;
    all)  run_unit; run_e2e ;;
    *)    echo "mode: unit | e2e | all" >&2; exit 2 ;;
esac
