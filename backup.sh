#!/bin/bash

# ============================================================
# backup.sh — database dumps of a project deployed with --with backup
# ============================================================
# Usage:
#   sudo bash backup.sh --slug shop now                 # take a dump now
#   sudo bash backup.sh --slug shop list                # list the dumps
#   sudo bash backup.sh --slug shop restore FILE        # restore a dump (asks for confirmation)
#   sudo bash backup.sh --slug shop restore FILE --yes  # ... without asking
#
# The dumps are files in /var/www/<slug>/backups, made by the <slug>_backup container of the backup
# module (one at start, then every 24 hours; kept --backup-keep days). PostgreSQL dumps are
# custom-format `.dump` files (pg_dump -Fc), MySQL dumps are `.sql.gz`.
#
# What restore does:
#   1. puts the application in maintenance mode (artisan down)
#   2. stops php, cron and the queue / horizon workers, so nothing writes to the database
#   3. replaces the database contents with the dump (pg_restore --clean / mysql)
#   4. starts the services again and brings the application back (artisan up)
# If the restore itself fails, the services are started again, the application stays in maintenance
# mode and the script prints what to check. The dump file is never modified.
#
# Restore replaces the CURRENT data: take a fresh dump first (`now`) if you may need it.
#
# Options:
#   --slug SLUG   Project slug (required)
#   --yes         Do not ask for confirmation before restore
#   -h, --help    Show this help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"

WWW_DIR="/var/www"
SLUG=""
ACTION=""
DUMP_FILE=""
ASSUME_YES=false
PROJECT_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    awk '!started { if (/^# =+$/) started = 1; next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug) SLUG="$2"; shift 2 ;;
            --yes)  ASSUME_YES=true; shift 1 ;;
            now|list)
                [[ -z "$ACTION" ]] || error "Only one action can be given (now, list or restore)"
                ACTION="$1"; shift 1 ;;
            restore)
                [[ -z "$ACTION" ]] || error "Only one action can be given (now, list or restore)"
                ACTION="restore"
                [[ $# -ge 2 && "$2" != --* ]] || error "restore needs a dump file (see: backup.sh --slug ${SLUG:-SLUG} list)"
                DUMP_FILE="$2"; shift 2 ;;
            *) error "Unknown argument: $1 (see --help)" ;;
        esac
    done

    [[ -n "$SLUG" ]] || error "--slug is required"
    [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || error "Invalid slug: ${SLUG}"
    [[ "${SLUG,,}" != nginxproxy ]] || error "The slug nginxproxy is reserved for the shared reverse proxy"
    [[ -n "$ACTION" ]] || error "An action is required: now, list or restore FILE"
    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    [[ -d "$PROJECT_DIR" ]] || error "Project not found: ${PROJECT_DIR}"
    if [[ ! -f "${PROJECT_DIR}/.config/backup/dump.sh" ]]; then
        error "Project ${SLUG} was not deployed with the backup module (no .config/backup/dump.sh). Deploy with --with backup."
    fi
}

dc() { (cd "$PROJECT_DIR" && docker compose "$@"); }

services() { dc config --services 2>/dev/null; }

backup_running() {
    [[ -n "$(dc ps --status running -q backup 2>/dev/null)" ]]
}

do_now() {
    backup_running || error "The backup container ${SLUG}_backup is not running. Start the project first (activate.sh or docker compose up -d)."
    info "Taking a dump..."
    local OUT
    OUT="$(dc exec -T backup /bin/sh /scripts/dump.sh | tail -n1)"
    info "Dump written: ${PROJECT_DIR}/backups/$(basename "$OUT")"
}

do_list() {
    if ! ls "${PROJECT_DIR}/backups"/"${SLUG}"-* > /dev/null 2>&1; then
        info "No dumps yet in ${PROJECT_DIR}/backups"
        return
    fi
    ls -lh --time-style=long-iso "${PROJECT_DIR}/backups"/"${SLUG}"-* | awk '{ printf "  %s %s  %8s  %s\n", $6, $7, $5, $8 }' | sed "s#${PROJECT_DIR}/backups/##"
}

confirm() {
    [[ "$ASSUME_YES" == true ]] && return 0
    echo -e "${YELLOW}This REPLACES the current database of ${SLUG} with ${DUMP_FILE}.${NC}"
    read -r -p "Type 'yes' to continue: " ANSWER
    [[ "$ANSWER" == "yes" ]] || error "Cancelled"
}

restore_worker() {
    [[ "$DUMP_FILE" =~ ^[A-Za-z0-9._-]+$ && "$DUMP_FILE" != *..* ]] || error "Invalid dump file name: ${DUMP_FILE}"
    [[ -f "${PROJECT_DIR}/backups/${DUMP_FILE}" ]] || error "No such dump: ${PROJECT_DIR}/backups/${DUMP_FILE} (see: backup.sh --slug ${SLUG} list)"

    # This check uses the image's tools, not a generated script: it is safe for older
    # deployments too, and never connects to the database or changes the dump.
    info "Checking the dump before stopping services..."
    if ! dc run --rm --no-deps -T --entrypoint /bin/sh backup -ec '
        umask 077
        case "$1" in
            *.dump) pg_restore --list "/backups/$1" > /dev/null ;;
            *.sql.gz)
                SQL=$(mktemp)
                trap '\''rm -f "$SQL"'\'' 0
                trap '\''exit 1'\'' 1 2 15
                gzip -dc "/backups/$1" > "$SQL"
                [ -s "$SQL" ] || { echo "empty SQL dump" >&2; exit 1; }
                ;;
            *) echo "unsupported dump type: $1" >&2; exit 1 ;;
        esac
    ' check-dump "$DUMP_FILE"; then
        error "Dump validation failed; the database and application services were not changed"
    fi
    confirm

    local SVC ALL
    STOP=()
    ALL="$(services)"
    for SVC in php cron queue horizon; do
        if grep -qx "$SVC" <<< "$ALL"; then STOP+=("$SVC"); fi
    done

    info "Enabling maintenance mode..."
    dc run --rm -T artisan down --retry=60 || error "Cannot enable maintenance mode; the database was not restored"
    RESTORE_STOPPED=true
    trap 'RESULT=$?; trap - EXIT; trap "" HUP INT TERM; if [[ "$RESULT" != 0 ]]; then
        if [[ -n "$SLUG" ]]; then docker rm -f "${SLUG}_restore_import" >/dev/null 2>&1 || true; fi
        if [[ "$RESTORE_STOPPED" == true ]]; then dc start "${STOP[@]}" || warn "Could not restart all application services"; fi
        warn "Restore interrupted or failed; maintenance remains enabled. Review the database before running artisan up."
        echo "  cd $PROJECT_DIR && docker compose run --rm artisan up"
    fi; exit "$RESULT"' EXIT
    trap 'exit 1' HUP INT TERM
    info "Stopping ${STOP[*]}..."
    dc stop "${STOP[@]}"

    info "Restoring ${DUMP_FILE}..."
    local RESTORED=true
    if ! dc run --rm --name "${SLUG}_restore_import" --no-deps -T --entrypoint /bin/sh backup /scripts/restore.sh "$DUMP_FILE"; then
        RESTORED=false
    fi

    info "Starting ${STOP[*]}..."
    dc start "${STOP[@]}"
    RESTORE_STOPPED=false

    if [[ "$RESTORED" != true ]]; then
        echo -e "${RED}[ERROR]${NC} The restore failed. The services are running again, the application stays in maintenance mode."
        echo "The dump file was not modified. Check the output above, then retry, or bring the application back with:"
        echo "  cd ${PROJECT_DIR} && docker compose run --rm artisan up"
        exit 1
    fi

    info "Disabling maintenance mode..."
    dc run --rm -T artisan up
    info "Restored ${DUMP_FILE} into the database of ${SLUG}"
    trap - EXIT HUP INT TERM
    exit 0
}

do_restore() { runtime_guarded restore_worker; }

main() {
    local ARG
    for ARG in "$@"; do
        if [[ "$ARG" == "-h" || "$ARG" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    check_root
    parse_args "$@"
    runtime_require python3 flock docker
    project_lock
    case "$ACTION" in
        now)     do_now ;;
        list)    do_list ;;
        restore) do_restore ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
