#!/usr/bin/env bash
# Full launch matrix. Only the Docker-in-Docker sandbox may run this destructive test helper.
set -euo pipefail
if [[ "${LARASHIP_TEST_SANDBOX:-}" != 1 || ! -f /.dockerenv || "$(id -u)" != 0 ]]; then
    echo "Full matrix requires the disposable sandbox: bash tests/run-local.sh full" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="${FULL_RESULTS_DIR:-/tmp/laraship-full-results}"
PHASE="${FULL_PHASE:-all}"
case "$PHASE" in all|base|options) ;; *) echo "FULL_PHASE must be all, base or options" >&2; exit 1 ;; esac
ONLY="${FULL_SCENARIOS:-}"
if [[ "$ONLY" && ! "$ONLY" =~ ^[A-Za-z0-9._,-]+$ ]]; then echo "FULL_SCENARIOS expects comma-separated scenario IDs" >&2; exit 1; fi
if [[ -n "${RESULTS_UID:-}${RESULTS_GID:-}" ]] && ! [[ "${RESULTS_UID:-}" =~ ^[0-9]+$ && "${RESULTS_GID:-}" =~ ^[0-9]+$ ]]; then
    echo "RESULTS_UID/GID must both be numeric" >&2; exit 1
fi
umask 077
if [[ -L "$RESULTS" || ( -e "$RESULTS" && ! -d "$RESULTS" ) ]]; then
    echo "Full matrix results require an empty real directory: $RESULTS" >&2; exit 1
fi
if [[ -d "$RESULTS" && -n "$(find "$RESULTS" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Full matrix results require an empty real directory: $RESULTS" >&2; exit 1
fi
mkdir -p "$RESULTS"
chmod 700 "$RESULTS"
printf 'scenario\texit\tpass\tskip\tfail\tseconds\n' > "$RESULTS/results.tsv"
FAILED=0
EXECUTED=0
REPORT_FILES=("$RESULTS" "$RESULTS/results.tsv" "$RESULTS/current")
finish_reports() {
    local result=$? report
    trap - EXIT
    if [[ -n "${RESULTS_UID:-}" ]]; then
        for report in "${REPORT_FILES[@]}"; do
            if [[ -e "$report" ]]; then chown --no-dereference "$RESULTS_UID:$RESULTS_GID" "$report" || result=1; fi
        done
    fi
    exit "$result"
}
trap finish_reports EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

reset_sandbox() {
    # This daemon belongs to the disposable sandbox, never the host Docker socket.
    docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network prune -f >/dev/null
    docker volume prune -af >/dev/null
    rm -rf -- /var/www
}
run_case() {
    local name="$1"; shift
    if [[ "$ONLY" ]]; then case ",$ONLY," in *",$name,"*) ;; *) return 0 ;; esac; fi
    local result=0 start=$SECONDS pass skip fail
    EXECUTED=$((EXECUTED+1))
    REPORT_FILES+=("$RESULTS/$name.tap" "$RESULTS/$name-deploy.log")
    reset_sandbox
    printf 'RUN %s\n' "$name"
    printf '%s\n' "$name" > "$RESULTS/current"
    timeout --kill-after=30s 30m env E2E_ALLOW=1 E2E_KEEP_LOG="$RESULTS/$name-deploy.log" "$@" > "$RESULTS/$name.tap" 2>&1 || result=$?
    pass=$(awk '/^ok / && !/# skip/ {n++} END {print n+0}' "$RESULTS/$name.tap")
    skip=$(awk '/^ok / && /# skip/ {n++} END {print n+0}' "$RESULTS/$name.tap")
    fail=$(awk '/^not ok / {n++} END {print n+0}' "$RESULTS/$name.tap")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$result" "$pass" "$skip" "$fail" "$((SECONDS-start))" >> "$RESULTS/results.tsv"
    if [[ "$result" != 0 ]]; then FAILED=1; printf 'FAIL %s (see %s/%s.tap)\n' "$name" "$RESULTS" "$name"
    else printf 'PASS %s (%s checks, %s skips)\n' "$name" "$pass" "$skip"; fi
}
cd "$ROOT"
if [[ "$PHASE" != options ]]; then
run_case unit bash -c '
    set -e
    for f in *.sh lib/*.sh modules/*.sh tests/*.sh .github/scripts/*.sh; do bash -n "$f"; done
    shellcheck -S warning -e SC2155 *.sh lib/*.sh modules/*.sh tests/*.sh .github/scripts/*.sh || exit
    bats --print-output-on-failure tests/static.bats tests/validation.bats tests/presets.bats tests/safety.bats tests/hardening.bats
'

# Container-DB Laravel / DB / Filament installation combinations.
for db in postgres mysql; do
    for version in 12.0 13.0; do
        for filament in 0 1; do
            run_case "deploy-$db-${version%.*}-filament$filament" env E2E_DB="$db" E2E_LARAVEL="$version" E2E_FILAMENT="$filament" E2E_EXTRAS=0 E2E_CONFIG=0 E2E_SSL=0 bats --print-output-on-failure tests/e2e.bats
        done
    done
    run_case "extras-config-$db" env E2E_DB="$db" E2E_LARAVEL= E2E_FILAMENT=0 E2E_EXTRAS=1 E2E_CONFIG=1 E2E_SSL=0 bats --print-output-on-failure tests/e2e.bats
    run_case "modules-$db" env E2E_DB="$db" bats --print-output-on-failure tests/e2e-modules.bats
    for branch in 12.x 13.x; do
        run_case "repo-$db-$branch" env E2E_DB="$db" E2E_BRANCH="$branch" bats --print-output-on-failure tests/e2e-repo.bats
    done
    run_case "migration-$db" env E2E_DB="$db" bats --print-output-on-failure tests/e2e-db-migration.bats
done

# Keep the independent install matrix, including invalid versions / advisory failures.
for install in laravel12-postgres laravel13-mysql laravel13-filament laravel12-filament native-postgres native-mysql repo-blocked-10.x repo-blocked-11.x laravel99-fails; do
    run_case "install-$install" env INSTALL_CASE="$install" bats --print-output-on-failure tests/install-matrix.bats
done
run_case proxy bats --print-output-on-failure tests/e2e-proxy.bats
run_case ssl-unavailable env E2E_DB=mysql E2E_LARAVEL= E2E_FILAMENT=0 E2E_EXTRAS=1 E2E_CONFIG=0 E2E_SSL=1 bats --print-output-on-failure tests/e2e.bats
fi
if [[ "$PHASE" != base ]]; then
    for db in postgres mysql; do
        for option in generated preset-admin preset-api preset-staging native-backup ssh-repo; do
            run_case "options-$option-$db" env E2E_DB="$db" E2E_OPTION_CASE="$option" bats --print-output-on-failure tests/e2e-options.bats
        done
    done
fi
if [[ "$ONLY" ]]; then
    IFS=, read -r -a requested_cases <<< "$ONLY"
    for requested_case in "${requested_cases[@]}"; do
        if ! awk -F '\t' -v name="$requested_case" '$1==name {found=1} END {exit !found}' "$RESULTS/results.tsv"; then
            echo "Requested scenario did not run: $requested_case" >&2; FAILED=1
        fi
    done
fi
if [[ "$EXECUTED" = 0 ]]; then echo "No scenarios ran" >&2; FAILED=1; fi
reset_sandbox
printf 'complete\n' > "$RESULTS/current"
cat "$RESULTS/results.tsv"
exit "$FAILED"
