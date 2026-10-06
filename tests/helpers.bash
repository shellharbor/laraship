# Shared helpers for the laraship bats tests.
# shellcheck shell=bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
DEPLOY="${REPO_ROOT}/deploy-laravel.sh"
SCRIPTS=(lib/runtime.sh lib/proxy.sh deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh update.sh backup.sh kubernetes.sh docker/entrypoint.sh .github/scripts/release-notes.sh tests/native-db.sh)

# KEY from an env-style file (first match).
env_val() { grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-; }

# Root project metadata is Compose dotenv; read the decoded value rather than its quoted spelling.
compose_env_val() {
    docker compose --project-directory "$(dirname "$1")" config --environment |
        awk -v prefix="$2=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }'
}

# Retry a command until it succeeds (up to N seconds).
eventually() {
    local timeout="$1"; shift
    local i
    for ((i = 0; i < timeout; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    "$@"
}

container_up() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Script output without ANSI colours.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

require_root() {
    [ "$(id -u)" -eq 0 ] || skip "root is required (run the tests through sudo or in the sandbox)"
}

# Run deploy-laravel.sh with a hard timeout: if validation ever lets bad
# arguments through, the script must not go on to a real deployment.
run_deploy() {
    run timeout 30 bash "${DEPLOY}" "$@"
    output="$(printf '%s' "${output}" | strip_ansi)"
}

# Same as run_deploy, for a copy of the script in another folder (used to test versions.env).
run_deploy_from() {
    local dir="$1"; shift
    run timeout 30 bash "${dir}/deploy-laravel.sh" "$@"
    output="$(printf '%s' "${output}" | strip_ansi)"
}

# Write a config file for --config (printf %b: \n and \r are interpreted) and print its path.
write_config() {
    local file="${BATS_TEST_TMPDIR}/deploy.conf"
    printf '%b' "$1" >"${file}"
    chmod "${2:-600}" "${file}"
    printf '%s' "${file}"
}

# A folder with a copy of the script and the given versions.env content.
versions_dir() {
    local dir="${BATS_TEST_TMPDIR}/ver"
    mkdir -p "${dir}"
    cp "${DEPLOY}" "${dir}/deploy-laravel.sh"
    cp -r "${REPO_ROOT}/lib" "${dir}/lib"
    printf '%b' "$1" >"${dir}/versions.env"
    printf '%s' "${dir}"
}

# Expect a rejection at the validation stage: exit code 1 and an error message.
assert_rejected() {
    local expected="$1"
    [ "${status}" -eq 1 ] || {
        echo "expected exit=1, got ${status}" >&2
        echo "${output}" >&2
        return 1
    }
    [[ "${output}" == *"${expected}"* ]] || {
        echo "output does not contain \"${expected}\"" >&2
        echo "${output}" >&2
        return 1
    }
}
