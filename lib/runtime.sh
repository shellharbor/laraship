#!/usr/bin/env bash
# Shared preflight and locks. Lock files outlive projects and must never be unlinked.
# shellcheck disable=SC2034
LOCK_DIR=/run/lock/laraship

runtime_require() {
    local TOOL
    for TOOL in "$@"; do
        command -v "$TOOL" >/dev/null 2>&1 || error "Required tool missing: $TOOL. Install it before retrying."
    done
}

runtime_lock_dir() {
    if [[ -L "$LOCK_DIR" ]]; then error "Refusing a symlink lock directory: $LOCK_DIR"; fi
    if [[ ! -d "$LOCK_DIR" ]]; then mkdir -p "$LOCK_DIR" || return 1; fi
    [[ "$(stat -c %u "$LOCK_DIR")" == "$EUID" ]] || error "Lock directory has an unexpected owner: $LOCK_DIR"
    chmod 700 "$LOCK_DIR" || return 1
}

project_lock() {
    runtime_require flock
    [[ ! -L "$WWW_DIR/$SLUG" ]] || error "Refusing a symlink project directory"
    runtime_lock_dir || return 1
    exec {PROJECT_LOCK_FD}>"$LOCK_DIR/project-$SLUG.lock"
    flock -w 60 "$PROJECT_LOCK_FD" || error "Another operation is running for project $SLUG; retry after it finishes"
}

# The secret arrives on stdin; the option file exists only during the client call.
mysql_private() (
    local CLIENT="$1" SECRET ESCAPED WORK RESULT=0
    shift
    IFS= read -r SECRET || [[ -n "$SECRET" ]] || true
    umask 077
    WORK=$(mktemp -d /tmp/laraship-mysql.XXXXXX) || exit 1
    trap 'rm -rf -- "$WORK"' EXIT
    trap 'exit 1' HUP INT TERM
    ESCAPED=${SECRET//\\/\\\\}
    ESCAPED=${ESCAPED//\"/\\\"}
    printf '[client]\npassword="%s"\n' "$ESCAPED" > "$WORK/client.cnf" || exit 1
    "$CLIENT" --defaults-extra-file="$WORK/client.cnf" "$@" || RESULT=$?
    exit "$RESULT"
)

# A signal addressed only to the caller must cancel the worker too, before it can commit.
runtime_cancel() {
    local PID="$1" CHILD
    local CHILDREN=()
    # Capture apply children before signalling: never kill a newly spawned rollback process.
    while IFS= read -r CHILD; do CHILDREN+=("$CHILD"); done < <(pgrep -P "$PID" || true)
    trap '' HUP INT TERM
    kill -TERM "${CHILDREN[@]}" "$PID" 2>/dev/null || true
}

runtime_guarded() {
    local GUARDED_PID GUARDED_RESULT=0 GUARDED_INTERRUPTED=false PREVIOUS_TRAPS
    runtime_require pgrep
    PREVIOUS_TRAPS=$(trap -p HUP INT TERM)
    "$@" &
    GUARDED_PID=$!
    trap 'GUARDED_INTERRUPTED=true; runtime_cancel "$GUARDED_PID"' HUP INT TERM
    wait "$GUARDED_PID" || GUARDED_RESULT=$?
    if [[ "$GUARDED_INTERRUPTED" == true ]]; then
        wait "$GUARDED_PID" 2>/dev/null || true
        GUARDED_RESULT=1
    fi
    trap - HUP INT TERM
    if [[ -n "$PREVIOUS_TRAPS" ]]; then eval "$PREVIOUS_TRAPS"; fi
    return "$GUARDED_RESULT"
}
