#!/usr/bin/env bash
# Sandbox entrypoint: starts the inner dockerd, copies the repository and runs the
# selected test suite.
#   unit  - shellcheck + static.bats + validation.bats + presets.bats + safety.bats (fast, no deployment)
#   e2e   - real deployment and lifecycle (slow, pulls images)
#   e2e-db-migration - Elestio dumps into official images on separate volumes
#   e2e-repo - deployment of an existing application (--repo) and update.sh (slow)
#   e2e-modules - --with filament,horizon (slow)
#   install [CASE...] - the install matrix (tests/install-matrix.bats, tests/e2e-repo.bats for repo-X.x cases); no
#                 cases means all of them (slow)
#   all   - unit, deployment, proxy, DB migration, repo and modules
#   full  - all supported launch combinations and the entire install matrix
set -euo pipefail

MODE="${1:-unit}"
shift || true
SRC=/repo
WORK=/opt/laraship

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
    (cd "${WORK}" && shellcheck -S warning -e SC2155 deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh update.sh backup.sh kubernetes.sh docker/*.sh lib/*.sh modules/*.sh .github/scripts/*.sh tests/native-db.sh tests/container-e2e.sh tests/kubernetes-e2e.sh)
    echo "==> bats: static + validation + presets + safety"
    bats --print-output-on-failure "${WORK}/tests/static.bats" "${WORK}/tests/validation.bats" "${WORK}/tests/presets.bats" "${WORK}/tests/safety.bats" "${WORK}/tests/hardening.bats"
    python3 -m unittest discover -s "$WORK/tests" -p 'test_*.py' -v
}

run_e2e() {
    echo "==> bats: e2e (db=${E2E_DB:-postgres}, filament=${E2E_FILAMENT:-1}, laravel=${E2E_LARAVEL:-default}, extras=${E2E_EXTRAS:-0}, config=${E2E_CONFIG:-0})"
    E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e.bats"
}

# The install matrix: every case is a real deployment, checked and removed. All cases run even if one fails.
INSTALL_CASES=(laravel12-postgres laravel13-mysql laravel13-filament laravel12-filament native-postgres native-mysql
               repo-blocked-10.x repo-blocked-11.x laravel99-fails repo-12.x repo-13.x)

run_install() {
    local cases=("$@") c failed=0
    if [[ ${#cases[@]} -eq 0 ]]; then cases=("${INSTALL_CASES[@]}"); fi
    for c in "${cases[@]}"; do
        echo "==> install case: ${c}"
        if [[ "$c" == repo-* && "$c" != repo-blocked-* ]]; then
            E2E_BRANCH="${c#repo-}" E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-repo.bats" || failed=1
        else
            INSTALL_CASE="$c" E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/install-matrix.bats" || failed=1
        fi
    done
    return "$failed"
}

run_e2e_modules() {
    echo "==> bats: e2e-modules (--with filament,horizon)"
    E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-modules.bats"
}

run_e2e_repo() {
    echo "==> bats: e2e-repo (--repo and update.sh)"
    E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-repo.bats"
}

cp -r "${SRC}" "${WORK}"
find "${WORK}" -name '*.sh' -exec chmod +x {} +
start_dockerd
reset_state
export LARASHIP_TEST_SANDBOX=1

case "${MODE}" in
    unit) run_unit ;;
    container) bash "$WORK/tests/container-e2e.sh" ;;
    kubernetes)
        bash "$WORK/.github/scripts/kubernetes-tools.sh" /opt/laraship-bin
        export PATH="/opt/laraship-bin:$PATH"
        bash "$WORK/tests/kubernetes-e2e.sh" ;;
    e2e)  run_e2e ;;
    e2e-proxy) E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-proxy.bats" ;;
    e2e-db-migration) E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-db-migration.bats" ;;
    e2e-repo) run_e2e_repo ;;
    e2e-modules) run_e2e_modules ;;
    install) run_install "$@" ;;
    full) bash "$WORK/tests/full-matrix.sh" ;;
    all)  run_unit; run_e2e; E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e-proxy.bats" "${WORK}/tests/e2e-db-migration.bats"; run_e2e_repo; run_e2e_modules ;;
    *)    echo "mode: unit | container | kubernetes | e2e | e2e-proxy | e2e-db-migration | e2e-repo | e2e-modules | install [CASE...] | all | full" >&2; exit 2 ;;
esac
