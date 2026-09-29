#!/bin/bash

# ============================================================
# activate.sh — activate/re-enable a deactivated project
# ============================================================
# Usage:
#   sudo bash activate.sh --slug cp
#
# What the script does:
#   1. Starts the project containers (docker compose up -d --build)
#   2. Restores the site config: nginxproxy/sites/<slug>.conf.disabled → <slug>.conf
#   3. Uncomments the slug entries in nginxproxy/docker-compose.yml
#   4. Restarts the project's php (if present) and nginx containers
#   5. Applies nginxproxy's docker-compose.yml and restarts it
#
# Options:
#   --slug SLUG           Project slug (required)
# ============================================================

set -euo pipefail

# ==================== Variables ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
SLUG=""

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
            *) error "Unknown argument: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]] && error "--slug is required"

    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Project not found: ${PROJECT_DIR}"
    fi
}

# ==================== Starting the project containers =
start_project_containers() {
    info "Starting containers of project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Failed to change directory to ${PROJECT_DIR}"
    
    if docker compose up -d --build; then
        info "Containers of project ${SLUG} started"
    else
        warn "Problems occurred while starting the containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Enabling the site config in nginxproxy ====
# deactivate.sh renames the config to <slug>.conf.disabled
enable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "${SITE_CONF}.disabled" ]]; then
        mv "${SITE_CONF}.disabled" "$SITE_CONF"
        info "Config ${SLUG}.conf enabled"
    elif [[ ! -f "$SITE_CONF" ]]; then
        warn "Config ${SITE_CONF} not found — the site will not be reachable through nginxproxy"
    fi
}

# ==================== Uncommenting in docker-compose.yml ====
uncomment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Uncommenting ${SLUG} entries in docker-compose.yml..."
    
    python3 - "${COMPOSE_FILE}" "${SLUG}" <<'PYEOF'
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
    
    # Uncomment the network in x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        result.append(line)
        i += 1
        # Process the network list
        while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
            if is_slug_item(lines[i]) and lines[i].strip().startswith("# "):
                # Uncomment the line with the target slug
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Uncomment the volume in the nginxproxy service
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
            if is_slug_item(lines[i]) and lines[i].strip().startswith("# "):
                # Uncomment the line with the target slug
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Uncomment the top-level network
    if re.match(r'^networks:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the commented-out block for the target slug
            if lines[i].strip().startswith(f"# {slug}:"):
                # Uncomment the block header
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
                i += 1
                # Uncomment all child items
                while i < len(lines) and lines[i].strip().startswith("#") and lines[i].startswith('  '):
                    uncommented = lines[i].replace("# ", "", 1)
                    result.append(uncommented)
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    # Uncomment the top-level volume
    if re.match(r'^volumes:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the commented-out block for the target slug
            if lines[i].strip().startswith(f"# {slug}_ssl_certificates:"):
                # Uncomment the block header
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
                i += 1
                # Uncomment all child items
                while i < len(lines) and lines[i].strip().startswith("#") and lines[i].startswith('  '):
                    uncommented = lines[i].replace("# ", "", 1)
                    result.append(uncommented)
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Entries for {slug} uncommented in docker-compose.yml")
PYEOF

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml updated successfully"
    else
        error "Failed to update docker-compose.yml"
    fi
}

# ==================== Restarting the project containers =
restart_project_services() {
    cd "${PROJECT_DIR}" || error "Failed to change directory to ${PROJECT_DIR}"

    # HTML projects have no php service — restart only the existing ones
    local SERVICES
    SERVICES=$(docker compose config --services 2>/dev/null | grep -xE 'php|nginx' | tr '\n' ' ' || true)
    info "Restarting ${SERVICES:-nginx }for project ${SLUG}..."

    # shellcheck disable=SC2086
    if docker compose restart ${SERVICES:-nginx}; then
        info "Restarted ${SERVICES:-nginx }for project ${SLUG}"
    else
        warn "Problems occurred while restarting the containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Restarting nginxproxy ========
restart_nginxproxy() {
    info "Applying nginxproxy's docker-compose.yml and restarting it..."

    # up -d is needed so the proxy reconnects to the project's uncommented network;
    # restart — to reload the site configs
    if (cd "${PROXY_DIR}" && docker compose up -d) && docker restart nginxproxy; then
        info "nginxproxy restarted successfully"
    else
        warn "Problems occurred while restarting nginxproxy"
    fi
}

# ==================== Summary output =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Project activation completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Status:         ACTIVATED"
    echo ""
    echo "What was done:"
    echo "  ✓ Project containers started (docker compose up -d --build)"
    echo "  ✓ nginxproxy/sites/${SLUG}.conf config enabled"
    echo "  ✓ Entries uncommented in nginxproxy/docker-compose.yml"
    echo "  ✓ Project php (if present) and nginx containers restarted"
    echo "  ✓ nginxproxy restarted"
    echo ""
    echo "The project is available at the address specified in the configuration"
    echo ""
    echo "To deactivate the project, use:"
    echo "  sudo bash deactivate.sh --slug ${SLUG}"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    
    info "Starting activation of project ${SLUG}..."
    echo ""
    
    start_project_containers
    enable_site_conf
    uncomment_in_docker_compose
    restart_project_services
    restart_nginxproxy
    
    print_summary
}

main "$@"
