#!/usr/bin/env bash
# Enforce the same policy against actual Compose runtimes, including existing images.
# shellcheck shell=bash

check_project_security() {
    local PROJECT="$1" LOCK_FILE="${2:-}" POLICY
    POLICY="$(tail -n +2 "$SCRIPT_DIR/laravel/.docker/php/security-policy.php")" || return 1
    (
        cd "$PROJECT" || exit 1
        timeout 30 docker compose run --rm --no-deps -T --entrypoint php php \
            -r "${POLICY}"$'\n''laraship_security_main(array_slice($argv, 1));' \
            -- "$LOCK_FILE" < /dev/null
    )
}
