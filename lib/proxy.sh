#!/usr/bin/env bash
# Callbacks edit PROXY_DIR in a private candidate; the live directory changes only after validation.
# shellcheck disable=SC2034

proxy_compose() {
    local DIRECTORY="$1"; shift
    local OPTIONS=()
    if [[ -n "${PROXY_RUNTIME_IMAGE_FILE:-}" ]]; then OPTIONS+=(-f "$PROXY_RUNTIME_IMAGE_FILE"); fi
    docker compose --project-name "${PROXY_PROJECT_NAME:-nginxproxy}" --project-directory "$DIRECTORY" -f "$DIRECTORY/docker-compose.yml" "${OPTIONS[@]}" "$@"
}

proxy_uses_model() {
    python3 "$SCRIPT_DIR/lib/proxy_config.py" managed "$PROXY_DIR"
}

proxy_resolve_identity() {
    local OWNER
    if [[ "${PROXY_IDENTITY_CHECKED:-false}" != true ]]; then
        if OWNER=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginxproxy 2>/dev/null); then
            [[ "$OWNER" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { error "Existing nginxproxy is not owned by a Compose project; explicit adoption is required"; return 1; }
            PROXY_PROJECT_NAME="$OWNER"
        fi
        PROXY_IDENTITY_CHECKED=true
    fi
}

proxy_config_update() {
    local STATUS
    proxy_resolve_identity || return 1
    STATUS=$(python3 "$SCRIPT_DIR/lib/proxy_config.py" "$1" "$PROXY_DIR" \
        --origin "${PROXY_REAL:-$PROXY_DIR}" --project-name "${PROXY_PROJECT_NAME:-nginxproxy}" --slug "$SLUG" --domain "${DOMAIN:-}") || return 1
    if [[ "$STATUS" == adopted ]]; then PROXY_ADOPTED=true; fi
}

proxy_keep_adoption_backup() {
    local ROOT="$WWW_DIR/.laraship-proxy-backups" BACKUP
    [[ ! -L "$ROOT" && ( ! -e "$ROOT" || -d "$ROOT" ) ]] || return 1
    (umask 077; mkdir -p "$ROOT") || return 1
    [[ "$(stat -c %u "$ROOT")" == "$EUID" ]] || return 1
    chmod 700 "$ROOT" || return 1
    BACKUP=$(mktemp -d "$ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
    cp -a "$PROXY_WORK/original" "$BACKUP/original" || return 1
    info "Original shared proxy configuration retained at $BACKUP/original"
}

proxy_same_file() {
    [[ -f "$1" && -f "$2" && ! -L "$1" && ! -L "$2" ]] && cmp -s "$1" "$2" &&
        [[ "$(stat -c '%a:%u:%g' "$1")" == "$(stat -c '%a:%u:%g' "$2")" ]]
}

proxy_copy_tree() {
    local SOURCE="$1" TARGET="$2" BASELINE="${3:-}" ENTRY NAME STAGED
    mkdir -p "$TARGET" || return 1
    # Apply only the candidate/original delta. Unrelated files may be updated by
    # the existing custom runtime while candidate validation is in progress.
    for ENTRY in "$TARGET/"* "$TARGET/".[!.]* "$TARGET/"..?*; do
        [[ -e "$ENTRY" || -L "$ENTRY" ]] || continue
        NAME=$(basename "$ENTRY")
        if [[ ! -e "$SOURCE/$NAME" ]]; then
            [[ -z "$BASELINE" || -e "$BASELINE/$NAME" ]] || continue
            [[ ! -L "$ENTRY" ]] || return 1
            if [[ -d "$ENTRY" && -d "$BASELINE/$NAME" ]]; then
                proxy_copy_tree "$SOURCE/$NAME" "$ENTRY" "$BASELINE/$NAME" || return 1
                rmdir -- "$ENTRY" 2>/dev/null || true
            else
                [[ -z "$BASELINE" ]] || proxy_same_file "$ENTRY" "$BASELINE/$NAME" || return 1
                rm -f -- "$ENTRY" || return 1
            fi
        fi
    done
    for ENTRY in "$SOURCE/"* "$SOURCE/".[!.]* "$SOURCE/"..?*; do
        [[ -e "$ENTRY" ]] || continue
        NAME=$(basename "$ENTRY")
        [[ ! -L "$ENTRY" && ! -L "$TARGET/$NAME" ]] || return 1
        if [[ -d "$ENTRY" ]]; then
            proxy_copy_tree "$ENTRY" "$TARGET/$NAME" "${BASELINE:+$BASELINE/$NAME}" || return 1
        elif [[ -n "$BASELINE" ]] && proxy_same_file "$ENTRY" "$BASELINE/$NAME"; then
            continue
        elif [[ -n "$BASELINE" && -e "$TARGET/$NAME" ]] &&
                ! proxy_same_file "$TARGET/$NAME" "$BASELINE/$NAME" && ! proxy_same_file "$TARGET/$NAME" "$ENTRY"; then
            return 1
        elif [[ "$TARGET" == "$PROXY_REAL/sites" ]]; then
            STAGED=$(mktemp "$TARGET/.laraship-conf.XXXXXX") || return 1
            cp -a "$ENTRY" "$STAGED" && mv -f -- "$STAGED" "$TARGET/$NAME" || { rm -f "$STAGED"; return 1; }
        else
            cp -a "$ENTRY" "$TARGET/$NAME" || return 1
        fi
    done
}

proxy_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' nginxproxy 2>/dev/null)" == true ]]
}

proxy_normalize_empty_sections() {
    python3 - "$PROXY_DIR/docker-compose.yml" <<'PY'
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
for i, line in enumerate(lines):
    match = re.fullmatch(r'( *)(networks|volumes):\s*(?:\[\]|\{\})?\s*', line)
    if not match:
        continue
    indent, key = match.groups()
    active = []
    for child in lines[i + 1:]:
        if not child.strip() or child.lstrip().startswith('#'):
            continue
        if len(child) - len(child.lstrip()) <= len(indent):
            break
        active.append(child)
    suffix = '' if active else (' {}' if not indent else ' []')
    lines[i] = f'{indent}{key}:{suffix}'
path.write_text('\n'.join(lines) + '\n', encoding="utf-8")
PY
}

proxy_verify() {
    local ATTEMPT
    for ATTEMPT in {1..10}; do
        if proxy_running && docker exec nginxproxy nginx -t; then
            sleep 1
            proxy_running && docker exec nginxproxy nginx -t && return 0
        fi
        sleep 1
    done
    return 1
}

proxy_finish() {
    local RESULT="$1" RECOVERED=true
    local IMAGE_OPTIONS=()
    if [[ -n "${PROXY_RUNTIME_IMAGE_FILE:-}" ]]; then IMAGE_OPTIONS=(--no-build --pull never); fi
    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$RESULT" != 0 && "$PROXY_CHANGED" == true && "$PROXY_COMMITTED" != true ]]; then
        warn "Proxy apply failed; restoring its previous configuration"
        if [[ "$PROXY_EXISTED" == true ]]; then
            proxy_copy_tree "$PROXY_WORK/original" "$PROXY_REAL" "$PROXY_DIR" || RECOVERED=false
            if [[ "$PROXY_WAS_RUNNING" == true ]]; then
                proxy_compose "$PROXY_REAL" up -d --no-deps --force-recreate "${IMAGE_OPTIONS[@]}" nginxproxy && proxy_verify || RECOVERED=false
            else
                proxy_compose "$PROXY_REAL" up --no-start --no-deps --force-recreate "${IMAGE_OPTIONS[@]}" nginxproxy || RECOVERED=false
            fi
        else
            proxy_compose "$PROXY_REAL" down --remove-orphans || RECOVERED=false
            if [[ "$RECOVERED" == true ]]; then
                proxy_copy_tree "$PROXY_WORK/original" "$PROXY_REAL" "$PROXY_DIR" && rmdir -- "$PROXY_REAL" || RECOVERED=false
            fi
        fi
    fi
    if [[ "$RECOVERED" == true ]]; then
        rm -rf -- "$PROXY_WORK"
    else
        warn "Proxy rollback failed. Recovery files retained at $PROXY_WORK/original; project data was not deleted"
        RESULT=1
    fi
    exit "$RESULT"
}

proxy_worker() {
    local PROXY_REAL="$PROXY_DIR" PROXY_WORK PROXY_EXISTED=false PROXY_WAS_RUNNING=false
    local PROXY_CHANGED=false PROXY_COMMITTED=false PROXY_ADOPTED=false PROXY_LOCK_FD
    local PROXY_RUNTIME_IMAGE_FILE='' IMAGE
    local PROXY_PROJECT_NAME=nginxproxy PROXY_IDENTITY_CHECKED=false
    local BUILD_OPTIONS=(--build) IMAGE_OPTIONS=()
    runtime_require docker python3 flock
    runtime_lock_dir || exit 1
    exec {PROXY_LOCK_FD}>"$LOCK_DIR/nginxproxy.lock"
    flock -w 60 "$PROXY_LOCK_FD" || error "Another shared proxy operation is running; retry after it finishes"
    [[ ! -L "$PROXY_REAL" ]] || error "Refusing a symlink shared proxy directory"
    [[ ! -e "$PROXY_REAL" || -d "$PROXY_REAL" ]] || error "Shared proxy path is not a directory: $PROXY_REAL"
    PROXY_WORK=$(mktemp -d "$WWW_DIR/.laraship-proxy.XXXXXX") || exit 1
    trap 'proxy_finish "$?"' EXIT
    trap 'exit 1' HUP INT TERM
    if [[ -d "$PROXY_REAL" ]]; then
        PROXY_EXISTED=true
        [[ -f "$PROXY_REAL/docker-compose.yml" ]] || error "Incomplete shared proxy directory: $PROXY_REAL"
        [[ -z "$(find "$PROXY_REAL" -type l -print -quit)" ]] || error "Refusing symlinks inside the shared proxy directory"
        cp -a "$PROXY_REAL" "$PROXY_WORK/original" || exit 1
        cp -a "$PROXY_REAL" "$PROXY_WORK/candidate" || exit 1
        if proxy_running; then PROXY_WAS_RUNNING=true; fi
    else
        local ORPHAN_PROXY
        ORPHAN_PROXY=$(docker ps -aq --filter 'name=^/nginxproxy$') || error "Cannot check whether the shared proxy exists"
        [[ -z "$ORPHAN_PROXY" ]] || error "Shared proxy container exists without its configuration; project data retained"
    fi
    PROXY_DIR="$PROXY_WORK/candidate"
    "$@" || exit 1
    if [[ "$PROXY_EXISTED" != true && ! -e "$PROXY_DIR" && ! -L "$PROXY_DIR" ]]; then
        info "No shared proxy configuration to change"
        exit 0
    fi
    [[ -z "$(find "$PROXY_DIR" -type l -print -quit)" ]] || error "Refusing symlinks inside the proxy candidate"
    # Keep the existing custom proxy runtime, including during rollback. A new
    # site's network/mount changes do not authorize rebuilding that runtime.
    if [[ "$PROXY_EXISTED" == true ]] && proxy_uses_model && IMAGE=$(docker inspect -f '{{.Image}}' nginxproxy 2>/dev/null); then
        proxy_resolve_identity || exit 1
        [[ "$IMAGE" =~ ^sha256:[a-f0-9]{64}$ ]] || error "Cannot identify the existing proxy image safely"
        python3 "$SCRIPT_DIR/lib/proxy_config.py" check-runtime "$PROXY_WORK/original" --project-name "$PROXY_PROJECT_NAME" || error "Existing proxy topology is not fully represented in Compose; live configuration unchanged"
        PROXY_RUNTIME_IMAGE_FILE="$PROXY_WORK/runtime-image.json"
        (umask 077; printf '{"services":{"nginxproxy":{"image":"%s","pull_policy":"never"}}}\n' "$IMAGE" > "$PROXY_RUNTIME_IMAGE_FILE") || exit 1
        BUILD_OPTIONS=()
        IMAGE_OPTIONS=(--no-build --pull never)
    fi
    proxy_normalize_empty_sections || error "Cannot normalize empty proxy sections"
    proxy_compose "$PROXY_DIR" config -q || error "Invalid candidate proxy Compose configuration; live proxy unchanged"
    # A separate container sees candidate networks/volumes without publishing ports.
    (umask 077; touch "$PROXY_WORK/nginx-test.log") || exit 1
    if ! proxy_compose "$PROXY_DIR" run --rm --no-deps -T "${BUILD_OPTIONS[@]}" --entrypoint nginx nginxproxy -t 2>&1 | tee "$PROXY_WORK/nginx-test.log"; then
        error "Invalid candidate proxy Nginx configuration or topology; live proxy unchanged"
    fi
    if grep -qi 'conflicting server name' "$PROXY_WORK/nginx-test.log"; then
        error "Conflicting proxy hostnames detected; live configuration unchanged"
    fi
    if [[ "$PROXY_EXISTED" == true && "$PROXY_ADOPTED" == true ]]; then
        proxy_keep_adoption_backup || error "Cannot preserve the original proxy; live configuration unchanged"
    fi
    if [[ "$PROXY_EXISTED" != true ]]; then
        mkdir -m 755 "$PROXY_REAL" || error "Shared proxy path appeared during preparation; existing data retained"
    fi
    PROXY_CHANGED=true
    proxy_copy_tree "$PROXY_DIR" "$PROXY_REAL" "$PROXY_WORK/original" || exit 1
    if [[ "$PROXY_WAS_RUNNING" == true ]] && cmp -s "$PROXY_WORK/original/docker-compose.yml" "$PROXY_DIR/docker-compose.yml"; then
        docker exec nginxproxy nginx -s reload || exit 1
    else
        proxy_compose "$PROXY_REAL" up -d --no-deps "${IMAGE_OPTIONS[@]}" nginxproxy || exit 1
    fi
    proxy_verify || error "Proxy did not become ready after applying the configuration"
    PROXY_COMMITTED=true
    info "Shared proxy configuration validated and applied"
    exit 0
}

proxy_transaction() {
    runtime_guarded proxy_worker "$@"
}
