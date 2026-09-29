#!/bin/bash
#
# Script that lists all deployed projects in /var/www
#

set -euo pipefail

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

WWW_DIR="/var/www"

# Function for printing information
info() {
    echo -e "${CYAN}[INFO]${NC}  $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC}  $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC}    $1"
}

# Root check
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (sudo)"
   exit 1
fi

# Header
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Deployed projects${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check that the directory exists
if [[ ! -d "$WWW_DIR" ]]; then
    error "Directory ${WWW_DIR} does not exist"
    exit 1
fi

# Project counter
PROJECT_COUNT=0
RUNNING_COUNT=0

# Scan directories in /var/www (excluding nginxproxy)
for PROJECT_DIR in "${WWW_DIR}"/*; do
    # Skip if it is not a directory
    if [[ ! -d "$PROJECT_DIR" ]]; then
        continue
    fi
    
    # Get the project name (slug)
    SLUG=$(basename "$PROJECT_DIR")
    
    # Skip nginxproxy
    if [[ "$SLUG" == "nginxproxy" ]]; then
        continue
    fi
    
    # Check that docker-compose.yml exists
    if [[ ! -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        continue
    fi
    
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    
    # Get the domain from .env
    DOMAIN="N/A"
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        DOMAIN=$(grep "^SITE_HOST=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    fi
    
    # Get the ports from .env
    PORT_HTTP=$(grep "^SITE_PORT_HTTP=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    PORT_HTTPS=$(grep "^SITE_PORT_HTTPS=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    PORT_PHP=$(grep "^PHP_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    
    # Get the database type
    DB_TYPE="N/A"
    if grep -q "^DB_POSTGRES_NAME=" "${PROJECT_DIR}/.env" 2>/dev/null; then
        DB_TYPE="PostgreSQL"
        DB_PORT=$(grep "^DB_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    elif grep -q "^DB_MYSQL_NAME=" "${PROJECT_DIR}/.env" 2>/dev/null; then
        DB_TYPE="MySQL"
        DB_PORT=$(grep "^DB_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    else
        DB_PORT="N/A"
    fi
    
    # Check the container status
    cd "$PROJECT_DIR" || continue
    
    TOTAL_CONTAINERS=$(docker compose ps -a --format "{{.Name}}" 2>/dev/null | wc -l)
    RUNNING_CONTAINERS=$(docker compose ps --format "{{.Name}}" --status running 2>/dev/null | wc -l)
    
    # Determine the project status
    if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
        STATUS="${GREEN}RUNNING${NC} (${RUNNING_CONTAINERS}/${TOTAL_CONTAINERS})"
        RUNNING_COUNT=$((RUNNING_COUNT + 1))
    elif [[ $TOTAL_CONTAINERS -gt 0 ]]; then
        STATUS="${YELLOW}STOPPED${NC} (0/${TOTAL_CONTAINERS})"
    else
        STATUS="${RED}NO CONTAINERS${NC}"
    fi
    
    # Check for an SSL certificate (stored in the docker volume <slug>_ssl_certificates)
    SSL_STATUS="${RED}NO${NC}"
    SSL_VOLUME_DIR=$(docker volume inspect -f '{{.Mountpoint}}' "${SLUG}_ssl_certificates" 2>/dev/null || true)
    if [[ -n "$SSL_VOLUME_DIR" && -e "${SSL_VOLUME_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
        SSL_STATUS="${GREEN}YES${NC}"
    fi
    
    # Print project information
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Project:${NC}    ${SLUG}"
    echo -e "${CYAN}Domain:${NC}     ${DOMAIN}"
    echo -e "${CYAN}Status:${NC}     ${STATUS}"
    echo -e "${CYAN}SSL:${NC}         ${SSL_STATUS}"
    echo -e "${CYAN}DB:${NC}         ${DB_TYPE} (port: ${DB_PORT})"
    echo -e "${CYAN}Ports:${NC}      HTTP: ${PORT_HTTP}, HTTPS: ${PORT_HTTPS}, PHP: ${PORT_PHP}"
    echo -e "${CYAN}Path:${NC}       ${PROJECT_DIR}"
    
    # Show the main containers
    if [[ $TOTAL_CONTAINERS -gt 0 ]]; then
        echo -e "${CYAN}Containers:${NC}"
        docker compose ps -a --format "  - {{.Name}}: {{.Status}}" 2>/dev/null | head -n 5
        if [[ $TOTAL_CONTAINERS -gt 5 ]]; then
            echo "  ... and $((TOTAL_CONTAINERS - 5)) more containers"
        fi
    fi
    
    # Management commands
    if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
        echo -e "${CYAN}Deactivate:${NC}   sudo bash deactivate.sh --slug ${SLUG}"
    else
        echo -e "${CYAN}Activate:${NC}     sudo bash activate.sh --slug ${SLUG}"
    fi
    echo -e "${CYAN}Remove:${NC}       sudo bash remove.sh --slug ${SLUG} --domain ${DOMAIN}"
    echo ""
done

# Summary statistics
echo -e "${BLUE}========================================${NC}"
echo -e "${CYAN}Total projects:${NC} ${PROJECT_COUNT}"
echo -e "${CYAN}Running:${NC}        ${GREEN}${RUNNING_COUNT}${NC}"
echo -e "${CYAN}Stopped:${NC}        ${YELLOW}$((PROJECT_COUNT - RUNNING_COUNT))${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check nginxproxy
if [[ -d "${WWW_DIR}/nginxproxy" ]]; then
    echo -e "${CYAN}Nginx Proxy:${NC}"
    cd "${WWW_DIR}/nginxproxy" || exit 0
    PROXY_STATUS=$(docker compose ps --format "{{.Status}}" 2>/dev/null | head -n 1 || echo "Not running")
    if [[ "$PROXY_STATUS" == *"Up"* ]]; then
        echo -e "  Status: ${GREEN}RUNNING${NC}"
    else
        echo -e "  Status: ${RED}STOPPED${NC}"
    fi
    
    # Show the number of sites in nginxproxy
    SITES_COUNT=$(ls -1 "${WWW_DIR}/nginxproxy/sites"/*.conf 2>/dev/null | wc -l)
    echo -e "  Sites in configuration: ${SITES_COUNT}"
    echo ""
fi

exit 0
