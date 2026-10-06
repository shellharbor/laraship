#!/bin/bash

# ============================================================
# update.sh — update a project that was deployed with deploy-laravel.sh --repo
# ============================================================
# Usage:
#   sudo bash update.sh --slug shop
#   sudo bash update.sh --slug shop --no-migrate --post-deploy "php artisan db:seed --force"
#
# What the script does:
#   1. Checks the project (deployed with --repo, containers running, no local changes)
#   2. Fetches the branch and checks it (nothing to do if already up to date)
#   3. Puts the old application in maintenance mode, then fast-forwards public_html
#   4. composer install --no-dev --optimize-autoloader
#   5. artisan migrate --force (unless --no-migrate)
#   6. artisan optimize:clear, queue:restart / horizon:terminate (when a worker exists), permissions,
#      restarts the php container (clears OPcache)
#   7. Runs the post-deploy commands (stored at deployment time, or --post-deploy)
#   8. Brings the application back (artisan up)
#
# If a step fails, the application is left in maintenance mode and the script prints
# how to roll back to the previous commit. Nothing is rolled back automatically:
# a migration may already have changed the database.
#
# Options:
#   --slug SLUG              Project slug (required)
#   --no-migrate             Skip artisan migrate
#   --post-deploy "CMDS"     Shell commands run in the php container after the update
#                            (replaces the ones stored at deployment time)
#   --reset                  Use `git reset --hard` to the remote branch instead of a fast-forward
#                            (for force-pushed branches; discards local commits)
#   --force                  Run all steps even if there are no new commits
#   -h, --help               Show this help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"

# ==================== Variables ====================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="/var/www"
SLUG=""
NO_MIGRATE=false
POST_DEPLOY_OVERRIDE=""
POST_DEPLOY_OVERRIDE_SET=false
HARD_RESET=false
FORCE=false

PROJECT_DIR=""
APP_DIR=""
REPO_URL=""
REPO_BRANCH=""
KEY_FILE=""
PREV_COMMIT=""
NEW_COMMIT=""

# ==================== Colored output ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    awk '/^# =====/ { n++; if (n == 3) exit } n >= 1 { print }' "${BASH_SOURCE[0]}" | sed -e '1d' -e 's/^# \{0,1\}//'
}

# ==================== Root check =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
    fi
}

# ==================== Argument parsing ============
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)         SLUG="$2";                                            shift 2 ;;
            --no-migrate)   NO_MIGRATE=true;                                      shift 1 ;;
            --post-deploy)  POST_DEPLOY_OVERRIDE="$2"; POST_DEPLOY_OVERRIDE_SET=true; shift 2 ;;
            --reset)        HARD_RESET=true;                                      shift 1 ;;
            --force)        FORCE=true;                                           shift 1 ;;
            *) error "Unknown argument: $1 (see --help)" ;;
        esac
    done

    [[ -z "$SLUG" ]] && error "--slug is required"
    [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || error "Invalid slug: ${SLUG}"
    [[ "${SLUG,,}" != nginxproxy ]] || error "The slug nginxproxy is reserved for the shared reverse proxy"
    if [[ "$POST_DEPLOY_OVERRIDE" == *$'\n'* ]]; then
        error "--post-deploy must be a single line (join commands with && or ;)"
    fi

    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    APP_DIR="${PROJECT_DIR}/public_html"
    [[ -d "$PROJECT_DIR" ]] || error "Project not found: ${PROJECT_DIR}"
}

# Reads KEY from the project's .deploy-meta (plain KEY=VALUE lines; the file is never sourced)
meta() {
    grep -E "^$1=" "${PROJECT_DIR}/.deploy-meta" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# git in public_html with the project's deploy key; safe.directory because the files belong to uid 1000
git_app() {
    local GIT_ENV=(env GIT_TERMINAL_PROMPT=0)
    if [[ -n "$KEY_FILE" ]]; then
        GIT_ENV+=("GIT_SSH_COMMAND=ssh -i ${PROJECT_DIR}/${KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PROJECT_DIR}/.config/known_hosts")
    fi
    "${GIT_ENV[@]}" git -C "$APP_DIR" -c safe.directory="$APP_DIR" "$@"
}

art() { (cd "$PROJECT_DIR" && docker compose run --rm --name "${SLUG}_update_artisan" -T artisan "$@"); }

# ==================== Checks =====================
check_project() {
    [[ -f "${PROJECT_DIR}/.deploy-meta" ]] || error "Project ${SLUG} was not deployed with deploy-laravel.sh --repo (no .deploy-meta). Nothing to update from."
    REPO_URL=$(meta REPO_URL)
    REPO_BRANCH=$(meta REPO_BRANCH)
    KEY_FILE=$(meta DEPLOY_KEY_FILE)
    [[ -n "$REPO_URL" && -n "$REPO_BRANCH" ]] || error "${PROJECT_DIR}/.deploy-meta is incomplete (REPO_URL / REPO_BRANCH)"
    [[ -d "${APP_DIR}/.git" ]] || error "${APP_DIR} is not a git checkout"
    command -v git &> /dev/null || error "git is not installed"

    if [[ -z "$(cd "$PROJECT_DIR" && docker compose ps --status running -q php 2>/dev/null)" ]]; then
        error "The php container of ${SLUG} is not running. Start the project first: sudo bash ${SCRIPT_DIR}/activate.sh --slug ${SLUG}"
    fi

    # Only tracked files count: composer and Laravel create untracked files (composer.lock, ...) by themselves
    if [[ -n "$(git_app status --porcelain --untracked-files=no)" ]]; then
        error "public_html has uncommitted changes to tracked files. Commit, stash or discard them first:  git -C ${APP_DIR} status"
    fi
}

# ==================== Failure: keep maintenance mode, explain the rollback ==========
fail_update() {
    trap - HUP INT TERM
    echo -e "${RED}[ERROR]${NC} Update failed at step: $1"
    echo "The application is left in maintenance mode. To roll back the code to the previous commit:"
    echo "  git -C ${APP_DIR} -c safe.directory=${APP_DIR} reset --hard ${PREV_COMMIT}"
    echo "  cd ${PROJECT_DIR} && docker compose run --rm composer install --no-dev --optimize-autoloader"
    echo "  cd ${PROJECT_DIR} && docker compose run --rm artisan up"
    echo "Database migrations that already ran are not reverted (artisan migrate:rollback if needed)."
    exit 1
}

run_step() {
    local DESC="$1"; shift
    info "${DESC}..."
    if ! "$@"; then
        fail_update "$DESC"
    fi
}

interrupt_update() {
    trap '' HUP INT TERM
    docker rm -f "${SLUG}_update_artisan" "${SLUG}_update_composer" "${SLUG}_update_permissions" >/dev/null 2>&1 || true
    # A cancelled exec post-deploy command lives in PHP; restart only this project's service.
    (cd "$PROJECT_DIR" && docker compose restart php) || warn "Could not restart PHP after cancellation"
    fail_update "interrupted update"
}

# ==================== Update =====================
prepare_update() {
    PREV_COMMIT=$(git_app rev-parse HEAD)
    info "Fetching ${REPO_BRANCH} from ${REPO_URL}..."
    git_app fetch --quiet origin "$REPO_BRANCH" || error "git fetch failed"
    NEW_COMMIT=$(git_app rev-parse FETCH_HEAD)

    if [[ "$PREV_COMMIT" == "$NEW_COMMIT" && "$FORCE" != true ]]; then
        info "Already up to date at $(git_app rev-parse --short HEAD). Nothing to do (use --force to run the steps anyway)."
        exit 0
    fi

    if [[ "$HARD_RESET" != true ]] && ! git_app merge-base --is-ancestor "$PREV_COMMIT" "$NEW_COMMIT"; then
        error "Cannot fast-forward ${REPO_BRANCH} (the branch was rewritten or has diverged). No code was changed. Use --reset to discard local history."
    fi
}

update_code() {
    if [[ "$PREV_COMMIT" != "$NEW_COMMIT" ]]; then
        if [[ "$HARD_RESET" == true ]]; then
            git_app reset --hard --quiet "$NEW_COMMIT" || return 1
        else
            git_app merge --ff-only --quiet "$NEW_COMMIT" || return 1
        fi
    fi
    info "Code: $(git_app rev-parse --short "$PREV_COMMIT") -> $(git_app rev-parse --short HEAD)"
}

update_worker() {
    cd "$PROJECT_DIR" || error "Failed to change to ${PROJECT_DIR}"

    info "Enabling maintenance mode..."
    art down --retry=60 || error "Cannot enable maintenance mode. Update stopped before changing application code."
    trap 'interrupt_update' HUP INT TERM

    run_step "Updating code" update_code

    # New files come from root's git: give them back to uid 1000 before composer runs
    run_step "Setting permissions" docker compose run --rm --name "${SLUG}_update_permissions" permissions
    run_step "composer install" docker compose run --rm --name "${SLUG}_update_composer" composer install --no-dev --optimize-autoloader --no-interaction

    if [[ "$NO_MIGRATE" != true ]]; then
        run_step "artisan migrate" art migrate --force
    else
        info "Skipping migrations (--no-migrate)"
    fi

    run_step "artisan optimize:clear" art optimize:clear

    if [[ -n "$(docker compose ps -aq queue 2>/dev/null)" ]]; then
        art queue:restart || warn "queue:restart failed (the worker restarts itself hourly)"
    fi
    if [[ -n "$(docker compose ps -aq horizon 2>/dev/null)" ]]; then
        art horizon:terminate || warn "horizon:terminate failed (restart it with: docker compose restart horizon)"
    fi

    run_step "Restarting php (clears OPcache)" docker compose restart php

    local POST
    POST=$(meta POST_DEPLOY)
    if [[ "$POST_DEPLOY_OVERRIDE_SET" == true ]]; then
        POST="$POST_DEPLOY_OVERRIDE"
    fi
    if [[ -n "$POST" ]]; then
        run_step "Post-deploy commands" docker compose exec -T -w /var/www/html php sh -c "$POST"
    fi

    info "Disabling maintenance mode..."
    art up || fail_update "artisan up"
    trap - HUP INT TERM
    cd - > /dev/null || true
    exit 0
}

apply_update() { runtime_guarded update_worker; }

# ==================== Main ===================
main() {
    for a in "$@"; do
        if [[ "$a" == "-h" || "$a" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    check_root
    parse_args "$@"
    runtime_require python3 flock docker
    project_lock
    check_project
    prepare_update
    apply_update
    info "Project ${SLUG} updated to $(git_app rev-parse --short HEAD)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
