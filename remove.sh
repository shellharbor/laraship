#!/bin/bash

# ============================================================
# remove.sh — full project removal
# ============================================================
# Usage:
#   sudo bash remove.sh --slug cp --domain cp.example.com
#
# What the script does:
#   1. Removes all entries from nginxproxy's docker-compose.yml
#   2. Removes the site config nginxproxy/sites/<slug>.conf
#   3. Applies the nginxproxy configuration (docker compose up -d)
#   4. Stops the project containers (docker compose down)
#   5. Removes all project volumes
#   6. Removes the project network
#   7. Restarts nginxproxy (docker restart nginxproxy)
#   8. Removes the project folder
#
# Options:
#   --slug SLUG           Project slug (required)
#   --domain DOMAIN       Project domain (required)
#   --db-root-password P  Root password of the native MySQL (needed to drop its database and user)
# ============================================================

set -euo pipefail

# ==================== Variables ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=lib/proxy.sh
source "$SCRIPT_DIR/lib/proxy.sh"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
SLUG=""
DOMAIN=""
DB_ROOT_PASSWORD=""

# ==================== Colored output ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

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
            --slug)    SLUG="$2";    shift 2 ;;
            --domain)  DOMAIN="$2";  shift 2 ;;
            --db-root-password) DB_ROOT_PASSWORD="$2"; shift 2 ;;
            *) error "Unknown argument: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]]   && error "--slug is required"
    [[ -z "$DOMAIN" ]] && error "--domain is required"

    [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || error "Invalid slug: ${SLUG}"
    [[ "${SLUG,,}" != nginxproxy ]] || error "The slug nginxproxy is reserved for the shared reverse proxy"

    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Project not found: ${PROJECT_DIR}"
    fi
}

# ==================== Deletion confirmation ========
confirm_deletion() {
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}                   ⚠️  WARNING! ⚠️${NC}"
    echo -e "${RED}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}You are about to COMPLETELY REMOVE the project:${NC}"
    echo ""
    echo -e "  Slug:           ${RED}${SLUG}${NC}"
    echo -e "  Domain:         ${RED}${DOMAIN}${NC}"
    echo -e "  Path:           ${RED}${PROJECT_DIR}${NC}"
    echo ""
    echo -e "${YELLOW}The following will be removed:${NC}"
    echo "  • All project containers"
    echo "  • All volumes (including database data)"
    echo "  • The project network"
    echo "  • The nginxproxy configuration"
    echo "  • The backup archive (if it exists)"
    echo "  • The project folder with all its files"
    echo ""
    echo -e "${RED}⚠️  THIS ACTION IS IRREVERSIBLE! ⚠️${NC}"
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo ""
    
    # Ask for confirmation
    read -p "Type 'yes' to confirm removal: " CONFIRMATION
    
    if [[ "$CONFIRMATION" != "yes" ]]; then
        echo ""
        info "Removal cancelled by user"
        exit 0
    fi
    
    echo ""
    info "Confirmation received. Starting removal..."
}

# ==================== Removing the site config ====
remove_from_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    # After deactivate.sh the config is stored as <slug>.conf.disabled
    if [[ ! -f "$SITE_CONF" && ! -f "${SITE_CONF}.disabled" ]]; then
        warn "Config ${SITE_CONF} not found, skipping."
        return
    fi

    info "Removing config ${SLUG}.conf..."

    rm -f "$SITE_CONF" "${SITE_CONF}.disabled" || error "Cannot remove site configuration"
    
}

# ==================== Removing from docker-compose.yml ====
remove_from_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Removing ${SLUG} entries from docker-compose.yml..."
    
    python3 - "${COMPOSE_FILE}" "${SLUG}" <<'PYEOF' || error "Failed to edit configuration"
import sys
import re

def in_service(lines, idx, name):
    """Line idx is inside service name: the nearest key above with indent 2 is name"""
    for j in range(idx - 1, -1, -1):
        m = re.match(r'^  ([\w.-]+):', lines[j])
        if m:
            return m.group(1) == name
        if re.match(r'^[^\s#]', lines[j]):
            return False
    return False

compose_file = sys.argv[1]
slug = sys.argv[2]

def is_slug_item(line):
    """Exact match of a list item ("- lms", "# - lms", "- lms_ssl_certificates:/...") —
    a substring would also hit other projects (lms → lms2)"""
    s = line.strip().lstrip('#').strip()
    if s.startswith('-'):
        s = s[1:].strip()
    return s.split(':', 1)[0] in (slug, f"{slug}_ssl_certificates")

with open(compose_file, 'r') as f:
    content = f.read()

lines = content.splitlines()
result = []
i = 0

while i < len(lines):
    line = lines[i]
    
    # Remove the network from x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        # Check whether the inline networks: [] syntax is used
        if line.strip() == "networks: []":
            # Leave as is - empty array
            result.append(line)
            i += 1
        else:
            result.append(line)
            i += 1
            # Collect the networks, skipping the target one
            remaining_networks = []
            while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
                if not is_slug_item(lines[i]):
                    remaining_networks.append(lines[i])
                i += 1
            # If no networks remain, switch to inline syntax
            if not remaining_networks:
                # Remove the previous "networks:" line and add "networks: []"
                result[-1] = "  networks: []"
            else:
                result.extend(remaining_networks)
        continue
    
    # Remove the volume from the nginxproxy service
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
            if not is_slug_item(lines[i]):
                result.append(lines[i])
            i += 1
        continue
    
    # Remove the top-level network
    if re.match(r'^networks:\s*(?:\{\})?\s*$', line):
        i += 1
        remaining_items = []
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the block for the target slug
            if lines[i].strip().lstrip("# ").startswith(f"{slug}:"):
                # Skip the whole network block (including child items)
                i += 1
                while i < len(lines) and lines[i].startswith('    '):
                    i += 1
            else:
                remaining_items.append(lines[i])
                i += 1
        # If items remain, add the networks: section
        if remaining_items:
            result.append("networks:")
            result.extend(remaining_items)
        else:
            # If no items remain, add an empty mapping
            result.append("networks: {}")
        continue
    
    # Remove the top-level volume
    if re.match(r'^volumes:\s*(?:\{\})?\s*$', line):
        i += 1
        remaining_items = []
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the block for the target slug
            if lines[i].strip().lstrip("# ").startswith(f"{slug}_ssl_certificates:"):
                # Skip the whole volume block (including child items)
                i += 1
                while i < len(lines) and lines[i].startswith('    '):
                    i += 1
            else:
                remaining_items.append(lines[i])
                i += 1
        # If items remain, add the volumes: section
        if remaining_items:
            result.append("volumes:")
            result.extend(remaining_items)
        else:
            # If no items remain, add an empty mapping
            result.append("volumes: {}")
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Entries for {slug} removed from docker-compose.yml")
PYEOF

}

# ==================== Applying the nginxproxy configuration ====
remove_proxy_site() {
    # A first deployment may have failed before the shared proxy was ever created.
    # proxy_worker already checked this state under the global lock.
    if [[ ! -e "$PROXY_DIR" && ! -L "$PROXY_DIR" ]]; then return 0; fi
    remove_from_docker_compose
    remove_from_nginx_conf
}
apply_proxy_config() {
    proxy_transaction remove_proxy_site || error "Cannot remove proxy routing; project and data retained"
}

# ==================== Stopping the project containers =
stop_project_containers() {
    info "Stopping containers of project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Failed to change directory to ${PROJECT_DIR}"
    
    docker compose down || error "Cannot stop project containers; data retained"
    
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Removing the project volumes =======
remove_project_volumes() {
    info "Removing volumes of project ${SLUG}..."
    
    # Get the list of volumes from the project's docker-compose.yml
    cd "${PROJECT_DIR}" || error "Failed to change directory to ${PROJECT_DIR}"
    
    local VOLUMES=$(grep -E "^  ${SLUG}_" docker-compose.yml | sed 's/://g' | awk '{print $1}' || true)
    
    if [[ -z "$VOLUMES" ]]; then
        info "No volumes found in docker-compose.yml"
    else
        for volume in $VOLUMES; do
            info "Removing volume: ${volume}"
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                docker volume rm "$volume" || error "Cannot remove volume $volume; project files retained"
            fi
        done
        info "All project volumes removed"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Removing the project network =======
remove_project_network() {
    info "Removing network of project ${SLUG}..."
    
    if docker network inspect "$SLUG" >/dev/null 2>&1; then
        docker network rm "$SLUG" || error "Cannot remove network $SLUG; project files retained"
    fi
    
    info "Project network removed"
}

# ==================== Removing the native database ===========
remove_native_database() {
    local DB_NATIVE="" DB_POSTGRES_NAME="" DB_POSTGRES_USER="" DB_MYSQL_NAME="" DB_MYSQL_USER=""
    # Check that the project's .env file exists
    local ENV_FILE="${PROJECT_DIR}/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        info "No .env file found, skipping the native database check"
        return
    fi
    
    # Read only managed database metadata; never import arbitrary environment keys.
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            DB_NATIVE|DB_POSTGRES_NAME|DB_POSTGRES_USER|DB_MYSQL_NAME|DB_MYSQL_USER) printf -v "$key" '%s' "$value" ;;
        esac
    done < "$ENV_FILE"
    
    # Project without a database (HTML)
    if [[ -z "${DB_POSTGRES_NAME:-}" && -z "${DB_MYSQL_NAME:-}" ]]; then
        info "Project has no database, skipping native database removal"
        return
    fi

    # Check whether a native database is used
    # Method 1: the DB_NATIVE flag (written by all deploy scripts)
    local IS_NATIVE=false
    if [[ "${DB_NATIVE:-}" == "true" ]]; then
        IS_NATIVE=true
    fi

    # Method 2: no flag (older projects) — check whether docker-compose.yml has a DB service.
    # deploy renames the service to "db", so look for db, db_postgres and db_mysql
    if [[ -z "${DB_NATIVE:-}" && -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        if ! grep -qE '^  db(_postgres|_mysql)?:' "${PROJECT_DIR}/docker-compose.yml" 2>/dev/null; then
            IS_NATIVE=true
            info "Native database detected (no db container in docker-compose.yml)"
        fi
    fi
    
    if [[ "$IS_NATIVE" != true ]]; then
        info "Project uses a containerized database, skipping native database removal"
        return
    fi
    
    local DB_ID
    for DB_ID in "${DB_POSTGRES_NAME:-}" "${DB_POSTGRES_USER:-}" "${DB_MYSQL_NAME:-}" "${DB_MYSQL_USER:-}"; do
        [[ -z "$DB_ID" || "$DB_ID" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || error "Unsafe database metadata; project files retained"
    done
    info "Native database detected, removing..."
    
    # Determine the database type from which variables are present
    if [[ -n "${DB_POSTGRES_NAME:-}" ]]; then
        # Drop the PostgreSQL database and user
        info "Removing PostgreSQL database: ${DB_POSTGRES_NAME}"
        
        if command -v psql &> /dev/null; then
            # Terminate all active connections
            sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_POSTGRES_NAME}';" 2>/dev/null || true
            
            # Drop the database
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${DB_POSTGRES_NAME}\";" 2>/dev/null && \
                info "Database ${DB_POSTGRES_NAME} removed" || \
                error "Failed to remove database ${DB_POSTGRES_NAME}"
            
            # Drop the user
            sudo -u postgres psql -c "DROP USER IF EXISTS \"${DB_POSTGRES_USER:-}\";" 2>/dev/null && \
                info "User ${DB_POSTGRES_USER:-} removed" || \
                error "Failed to remove user ${DB_POSTGRES_USER:-}"
        else
            error "PostgreSQL client is missing; project files retained"
        fi
        
    elif [[ -n "${DB_MYSQL_NAME:-}" ]]; then
        # Drop the MySQL database and user
        info "Removing MySQL database: ${DB_MYSQL_NAME}"

        if command -v mysql &> /dev/null; then
            # The system MySQL root password is not stored in .env — it is passed via --db-root-password
            local ROOT_PW="${DB_ROOT_PASSWORD:-}"
            if [[ -n "$ROOT_PW" ]]; then
                # Drop the database
                mysql_private mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_MYSQL_NAME}\`;" <<< "$ROOT_PW" 2>/dev/null && \
                    info "Database ${DB_MYSQL_NAME} removed" || \
                    error "Failed to remove database ${DB_MYSQL_NAME}"

                # Drop the user (deploy creates 'user'@'%', older versions — 'user'@'localhost')
                mysql_private mysql -u root -e "DROP USER IF EXISTS '${DB_MYSQL_USER:-}'@'%', '${DB_MYSQL_USER:-}'@'localhost';" <<< "$ROOT_PW" 2>/dev/null && \
                    info "User ${DB_MYSQL_USER:-} removed" || \
                    error "Failed to remove user ${DB_MYSQL_USER:-}"

                mysql_private mysql -u root -e "FLUSH PRIVILEGES;" <<< "$ROOT_PW" 2>/dev/null || true
            else
                error "MySQL root password is required (--db-root-password); project files retained"
            fi
        else
            error "MySQL client is missing; project files retained"
        fi
    fi
}

# ==================== Removing the backup archive =========
remove_backup_archive() {
    # Check that the project's .env file exists
    local ENV_FILE="${PROJECT_DIR}/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        info "No .env file found, skipping the backup archive check"
        return
    fi
    
    # Read the backup archive path from .env
    local BACKUP_ARCHIVE_PATH=$(grep "^BACKUP_ARCHIVE_PATH=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    
    if [[ -z "$BACKUP_ARCHIVE_PATH" ]]; then
        info "Backup archive path not found in .env, skipping removal"
        return
    fi
    
    # Check that the archive exists and remove it
    if [[ -f "$BACKUP_ARCHIVE_PATH" ]]; then
        info "Removing backup archive: ${BACKUP_ARCHIVE_PATH}"
        rm -f -- "$BACKUP_ARCHIVE_PATH" || error "Cannot remove backup archive; project files retained"
        info "Backup archive removed successfully"
    else
        info "Backup archive not found at: ${BACKUP_ARCHIVE_PATH}"
    fi
}

# ==================== Removing the project folder =========
remove_project_directory() {
    info "Removing project folder ${PROJECT_DIR}..."
    
    rm -rf -- "${PROJECT_DIR}" || error "Cannot remove project directory"
    
}

# ==================== Summary output =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Project removal completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Domain:         ${DOMAIN}"
    echo "  Status:         COMPLETELY REMOVED"
    echo ""
    echo "What was removed:"
    echo "  ✓ nginxproxy/sites/${SLUG}.conf configuration"
    echo "  ✓ Entries from nginxproxy/docker-compose.yml"
    echo "  ✓ Project containers stopped"
    echo "  ✓ All project volumes removed"
    echo "  ✓ Project network removed"
    echo "  ✓ Backup archive (if it existed)"
    echo "  ✓ Project folder ${PROJECT_DIR} removed"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    runtime_require python3 flock docker
    project_lock
    parse_args "$@"
    if [[ "${LARASHIP_CONTAINER:-0}" == 1 ]]; then
        if grep -q '^DB_NATIVE=true$' "$PROJECT_DIR/.env" || {
            grep -qE '^DB_(POSTGRES|MYSQL)_NAME=.+' "$PROJECT_DIR/.env" &&
            ! grep -q '^DB_NATIVE=false$' "$PROJECT_DIR/.env" &&
            ! grep -qE '^  db(_postgres|_mysql)?:' "$PROJECT_DIR/docker-compose.yml";
        }; then
            error "Native database removal requires the native Bash runner on the server; project retained"
        fi
    fi
    
    local STORED_DOMAIN
    STORED_DOMAIN=$(sed -n 's/^SITE_HOST=//p' "$PROJECT_DIR/.env" | head -n1)
    [[ -n "$STORED_DOMAIN" && "${STORED_DOMAIN,,}" == "${DOMAIN,,}" ]] ||
        error "Domain mismatch: project $SLUG is configured for $STORED_DOMAIN"
    # Ask for deletion confirmation
    confirm_deletion
    
    apply_proxy_config
    stop_project_containers
    remove_project_volumes
    remove_project_network
    remove_native_database
    remove_backup_archive
    remove_project_directory
    
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
