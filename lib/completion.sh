#!/usr/bin/env bash
# Deployment completion is armed only after full argument validation.
# shellcheck disable=SC2034

completion_snapshot() {
    local KEY
    for KEY in SCRIPT_VERSION COMPLETION_EXIT_CODE COMPLETION_STAGE COMPLETION_STARTED_EPOCH RUNTIME_LAST_SIGNAL \
        SLUG DOMAIN WWW_DIR SITE_SCHEME LARAVEL_VERSION DB_TYPE DB_NATIVE PORT_POSTGRES PORT_MYSQL \
        DB_POSTGRES_NAME DB_POSTGRES_USER DB_POSTGRES_PASSWORD DB_MYSQL_NAME DB_MYSQL_USER DB_MYSQL_PASSWORD \
        PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS REDIS_PASSWORD ENABLE_BASIC_AUTH AUTH_USER AUTH_PASSWORD \
        COMPLETION_FILAMENT FILAMENT_EMAIL FILAMENT_NAME FILAMENT_PASSWORD OBTAIN_SSL BACKUP_FILE_PATH \
        COMPLETION_HTTP_READY COMPLETION_PROXY_READY COMPLETION_INCLUDE_SECRETS ON_COMPLETE \
        COMPLETION_ENDPOINT COMPLETION_TOKEN_FILE COMPLETION_TIMEOUT ALLOW_INSECURE_ENDPOINT; do
        printf '%s\0%s\0' "$KEY" "${!KEY-}"
    done
}

validate_completion() {
    if [[ -z "$ON_COMPLETE$COMPLETION_ENDPOINT$COMPLETION_TOKEN_FILE" &&
          "$COMPLETION_INCLUDE_SECRETS" == false && "$COMPLETION_TIMEOUT" == 30 ]]; then
        return 0
    fi
    completion_snapshot | python3 "$SCRIPT_DIR/lib/completion.py" --validate ||
        error "Invalid deployment completion configuration (check paths, permissions, URL and timeout)"
}

completion_finalize() {
    local COMPLETION_EXIT_CODE="$1" COMPLETION_FILAMENT=false
    [[ "$BASHPID" == "$COMPLETION_OWNER_PID" && "$COMPLETION_SENT" != true ]] || return 0
    COMPLETION_SENT=true
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    # Release the project's lock only after deployment/rollback work has finished.
    if [[ -n "${PROJECT_LOCK_FD:-}" ]]; then
        exec {PROJECT_LOCK_FD}>&-
        unset PROJECT_LOCK_FD
    fi
    if module_enabled filament; then COMPLETION_FILAMENT=true; fi
    completion_snapshot | python3 "$SCRIPT_DIR/lib/completion.py" ||
        warn "Deployment completion delivery failed; the deployment exit status is unchanged"
    exit "$COMPLETION_EXIT_CODE"
}

completion_arm() {
    [[ "$DRY_RUN" != true && -n "$ON_COMPLETE$COMPLETION_ENDPOINT" ]] || return 0
    COMPLETION_OWNER_PID=$BASHPID
    COMPLETION_SENT=false
    RUNTIME_LAST_SIGNAL=""
    SITE_SCHEME=http
    COMPLETION_STARTED_EPOCH=$(date +%s)
    COMPLETION_STAGE=preflight
    trap 'completion_finalize "$?"' EXIT
    trap 'RUNTIME_LAST_SIGNAL=HUP; exit 129' HUP
    trap 'RUNTIME_LAST_SIGNAL=INT; exit 130' INT
    trap 'RUNTIME_LAST_SIGNAL=TERM; exit 143' TERM
}
