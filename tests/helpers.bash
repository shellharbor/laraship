# Shared helpers for the laravel-deploy bats tests.
# shellcheck shell=bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
DEPLOY="${REPO_ROOT}/deploy-laravel.sh"
SCRIPTS=(deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh)

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
