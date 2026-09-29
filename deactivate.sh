#!/bin/bash

# ============================================================
# deactivate.sh — deactivate/disable a project without removing it
# ============================================================
# Usage:
#   sudo bash deactivate.sh --slug cp
#
# What the script does:
#   1. Stops the project containers (docker compose down)
#   2. Disables the site config: nginxproxy/sites/<slug>.conf → <slug>.conf.disabled
#   3. Comments out the slug entries in nginxproxy/docker-compose.yml
#   4. Restarts nginxproxy (docker restart nginxproxy)
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

# ==================== Stopping the project containers =
stop_project_containers() {
    info "Stopping containers of project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Failed to change directory to ${PROJECT_DIR}"
    
    if docker compose down; then
        info "Containers of project ${SLUG} stopped"
    else
        warn "Problems occurred while stopping the containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Disabling the site config in nginxproxy ====
# Project containers are stopped: if sites/<slug>.conf is left in place, the proxy nginx
# will not resolve upstream <slug>_nginx, will fail to start — and every site will stop working
disable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "$SITE_CONF" ]]; then
        mv "$SITE_CONF" "${SITE_CONF}.disabled"
        info "Config ${SLUG}.conf disabled (renamed to ${SLUG}.conf.disabled)"
    else
        warn "Config ${SITE_CONF} not found, skipping."
    fi
}

# ==================== Commenting out in docker-compose.yml ====
comment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Commenting out ${SLUG} entries in docker-compose.yml..."
    
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
    
    # Comment out the network in x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        result.append(line)
        i += 1
        # Process the network list
        while i < len(lines) and lines[i].strip().startswith("-"):
            if is_slug_item(lines[i]):
                # Comment out the line with the target slug, preserving indentation
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Comment out the volume in the nginxproxy service
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            if is_slug_item(lines[i]):
                # Comment out the line with the target slug, preserving indentation
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Comment out the top-level network
    if re.match(r'^networks:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the block for the target slug
            if lines[i].strip().startswith(f"{slug}:"):
                # Comment out the block header, preserving indentation
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
                i += 1
                # Comment out all child items
                while i < len(lines) and lines[i].startswith('    '):
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    result.append(" " * indent + "# " + lines[i].strip())
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    # Comment out the top-level volume
    if re.match(r'^volumes:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Check whether a new top-level section has started
            if lines[i] and not lines[i].startswith(' '):
                break
            # If this is the block for the target slug
            if lines[i].strip().startswith(f"{slug}_ssl_certificates:"):
                # Comment out the block header, preserving indentation
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
                i += 1
                # Comment out all child items
                while i < len(lines) and lines[i].startswith('    '):
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    result.append(" " * indent + "# " + lines[i].strip())
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Entries for {slug} commented out in docker-compose.yml")
PYEOF

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml updated successfully"
    else
        error "Failed to update docker-compose.yml"
    fi
}

# ==================== Restarting nginxproxy ========
restart_nginxproxy() {
    info "Restarting nginxproxy..."
    
    if docker restart nginxproxy; then
        info "nginxproxy restarted successfully"
    else
        warn "Problems occurred while restarting nginxproxy"
    fi
}

# ==================== Summary output =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Project deactivation completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Status:         DEACTIVATED"
    echo ""
    echo "What was done:"
    echo "  ✓ Project containers stopped (docker compose down)"
    echo "  ✓ nginxproxy/sites/${SLUG}.conf config disabled (.disabled)"
    echo "  ✓ Entries commented out in nginxproxy/docker-compose.yml"
    echo "  ✓ nginxproxy restarted"
    echo ""
    echo "To activate the project, use:"
    echo "  sudo bash activate.sh --slug ${SLUG}"
    echo ""
    echo "To remove the project completely, use:"
    echo "  sudo bash remove.sh --slug ${SLUG} --domain <domain>"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    
    info "Starting deactivation of project ${SLUG}..."
    echo ""
    
    stop_project_containers
    disable_site_conf
    comment_in_docker_compose
    restart_nginxproxy
    
    print_summary
}

main "$@"
