#!/usr/bin/env bash
# Callbacks edit PROXY_DIR in a private candidate; the live directory changes only after validation.
# shellcheck disable=SC2034

proxy_compose() {
    docker compose --project-name nginxproxy --project-directory "$1" -f "$1/docker-compose.yml" "${@:2}"
}

proxy_copy_tree() {
    local SOURCE="$1" TARGET="$2" ENTRY NAME STAGED
    mkdir -p "$TARGET" || return 1
    # Preserve directory inodes used by bind mounts, and remove every entry absent in the snapshot.
    for ENTRY in "$TARGET/"* "$TARGET/".[!.]* "$TARGET/"..?*; do
        [[ -e "$ENTRY" || -L "$ENTRY" ]] || continue
        NAME=$(basename "$ENTRY")
        if [[ ! -e "$SOURCE/$NAME" ]]; then rm -rf -- "$ENTRY" || return 1; fi
    done
    for ENTRY in "$SOURCE/"* "$SOURCE/".[!.]* "$SOURCE/"..?*; do
        [[ -e "$ENTRY" ]] || continue
        NAME=$(basename "$ENTRY")
        [[ ! -L "$ENTRY" && ! -L "$TARGET/$NAME" ]] || return 1
        if [[ -d "$ENTRY" ]]; then
            proxy_copy_tree "$ENTRY" "$TARGET/$NAME" || return 1
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
    trap - EXIT
    trap '' HUP INT TERM
    if [[ "$RESULT" != 0 && "$PROXY_CHANGED" == true && "$PROXY_COMMITTED" != true ]]; then
        warn "Proxy apply failed; restoring its previous configuration"
        if [[ "$PROXY_EXISTED" == true ]]; then
            proxy_copy_tree "$PROXY_WORK/original" "$PROXY_REAL" || RECOVERED=false
            if [[ "$PROXY_WAS_RUNNING" == true ]]; then
                proxy_compose "$PROXY_REAL" up -d --force-recreate nginxproxy && proxy_verify || RECOVERED=false
            else
                proxy_compose "$PROXY_REAL" up --no-start --force-recreate nginxproxy || RECOVERED=false
            fi
        else
            proxy_compose "$PROXY_REAL" down --remove-orphans || RECOVERED=false
            if [[ "$RECOVERED" == true ]]; then rm -rf -- "$PROXY_REAL" || RECOVERED=false; fi
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
    local PROXY_CHANGED=false PROXY_COMMITTED=false PROXY_LOCK_FD
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
        [[ -f "$PROXY_REAL/docker-compose.yml" && -d "$PROXY_REAL/sites" ]] || error "Incomplete shared proxy directory: $PROXY_REAL"
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
    proxy_normalize_empty_sections || error "Cannot normalize empty proxy sections"
    proxy_compose "$PROXY_DIR" config -q || error "Invalid candidate proxy Compose configuration; live proxy unchanged"
    # A separate container sees candidate networks/volumes without publishing ports.
    proxy_compose "$PROXY_DIR" run --rm --no-deps -T --build --entrypoint nginx nginxproxy -t ||
        error "Invalid candidate proxy Nginx configuration or topology; live proxy unchanged"
    PROXY_CHANGED=true
    proxy_copy_tree "$PROXY_DIR" "$PROXY_REAL" || exit 1
    if [[ "$PROXY_WAS_RUNNING" == true ]] && cmp -s "$PROXY_WORK/original/docker-compose.yml" "$PROXY_DIR/docker-compose.yml"; then
        docker exec nginxproxy nginx -s reload || exit 1
    else
        proxy_compose "$PROXY_REAL" up -d nginxproxy || exit 1
    fi
    proxy_verify || error "Proxy did not become ready after applying the configuration"
    PROXY_COMMITTED=true
    info "Shared proxy configuration validated and applied"
    exit 0
}

proxy_transaction() {
    runtime_guarded proxy_worker "$@"
}
