#!/bin/bash
set -euo pipefail

# ============================================================
# deploy-laravel.sh — deploy Laravel (+ Filament) in Docker
# ============================================================
# Usage:
#   sudo bash deploy-laravel.sh \
#     --slug m311 \
#     --domain m311.example.com \
#     --db-type postgres \
#     --install-filament --filament-email admin@example.com \
#     --ssl-email admin@example.com
#
# All passwords and DB names are generated automatically unless given explicitly.
#
# Required arguments:
#   --domain DOMAIN              Site domain (without --slug, a random slug is prepended to it)
#   --db-type postgres|mysql     DB type
#   --ssl-email EMAIL            Email for Let's Encrypt (not needed with --no-ssl)
#
# Project:
#   --slug SLUG                  Project identifier (random by default)
#   --laravel-version X.Y        Laravel version (minimum 10.0, default 13.0)
#   --create-backup              Create a zip archive of the project in /tmp after deployment
#   --endpoint URL               Send project data (JSON, PUT) to URL
#
# Filament:
#   --install-filament           Install filament/filament and the /admin panel
#   --filament-email EMAIL       Admin email (required with --install-filament)
#   --filament-name NAME         Admin name (generated if not given)
#   --filament-password PASS     Admin password (generated if not given)
#
# Database:
#   --db-native                  Use a database on the host instead of in a container
#   --db-root-password PASS      Root password of native MySQL (required with --db-native + mysql)
#   --db-mysql-name, --db-mysql-user, --db-mysql-password, --db-mysql-root-password
#   --db-postgres-name, --db-postgres-user, --db-postgres-password
#
# Ports (default: a random free port from the range):
#   --port-http      8100–8400      --port-php       9100–9600
#   --port-https     4100–4300      --port-redis     6500–6800
#   --port-mysql     3400–3600      --port-postgres  5500–5800
#   For a native DB the default port is 3306 / 5432.
#
# Other:
#   --redis-password PASS        Redis password
#   --create-dhparam             Create dhparam.pem for SSL (takes a few minutes)
#   --enable-basic-auth          Enable HTTP Basic Authentication
#   --auth-user USER             Basic Auth user (generated if not given)
#   --auth-password PASS         Basic Auth password (generated if not given)
#   --no-ssl                     Do not obtain an SSL certificate
#   -h, --help                   Show this help
#
# The script must be located next to the template folders laravel/ and nginxproxy/.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
APP_TYPE="laravel"
TEMPLATE_DIR="${SCRIPT_DIR}/${APP_TYPE}"

# ======================== Colors ============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Prints this file's header as help
usage() {
    awk 'NR < 5 { next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ==================== Random credential generation ====================
# random_string <character set for tr> <length>
random_string() {
    local CHARSET=$1
    local LENGTH=$2
    local RESULT=""
    # head closes the pipe before tr finishes (SIGPIPE) — with pipefail that is a non-zero exit code, hence || true
    RESULT=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$CHARSET" | head -c "$LENGTH") || true
    echo "$RESULT"
}

# generate_random_name - generates a name (15 characters)
# Always starts with a letter for SQL compatibility
generate_random_name() {
    echo "$(random_string 'a-z' 1)$(random_string 'a-z0-9' 14)"
}

# generate_random_password - generates a strong password (15 characters)
# Without characters that break sed (&, |, /, \), .env and docker compose ($, #, =, quotes)
generate_random_password() {
    random_string 'A-Za-z0-9@%_+-' 15
}

# generate_random_slug - generates a random slug (8 characters)
generate_random_slug() {
    random_string 'a-z0-9' 8
}

# Escapes a string for the right-hand side of a sed substitution (s|...|HERE|)
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# ==================== Free port lookup ====================
# find_free_port <min> <max> <description>
# Picks a random free port from the range [min, max]
find_free_port() {
    local MIN=$1
    local MAX=$2
    local DESC=$3
    local RANGE=$((MAX - MIN + 1))
    local ATTEMPTS=0
    local MAX_ATTEMPTS=100

    while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
        local PORT=$(( RANDOM % RANGE + MIN ))
        # Use ss to check that the port is not in use
        if ! ss -tlnp 2>/dev/null | grep -q ":${PORT} " && \
           ! ss -ulnp 2>/dev/null | grep -q ":${PORT} "; then
            echo "$PORT"
            return 0
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
    done

    error "Could not find a free port for ${DESC} in range ${MIN}-${MAX}"
}

# ==================== Install missing packages ====================
ensure_packages() {
    local MISSING=()
    local PKG
    for PKG in "$@"; do
        command -v "$PKG" &>/dev/null || MISSING+=("$PKG")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Not installed: ${MISSING[*]}. Installing..."
        apt-get update -qq && apt-get install -y -qq "${MISSING[@]}"
    fi
}

# ==================== Root check =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)."
    fi
}

# ==================== Check/create /var/www ====
ensure_www_dir() {
    if [[ ! -d "$WWW_DIR" ]]; then
        info "Directory ${WWW_DIR} does not exist, creating..."
        mkdir -p "$WWW_DIR" || error "Failed to create directory ${WWW_DIR}"
        info "Directory ${WWW_DIR} created successfully"
    else
        info "Directory ${WWW_DIR} already exists"
    fi
}

# ==================== Docker installation ======================
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker is already installed: $(docker --version)"
        return
    fi

    info "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    info "Docker installed: $(docker --version)"
}

# ==================== nginxproxy initialization ===============
init_nginxproxy() {
    if [[ -d "${PROXY_DIR}" ]]; then
        info "Directory ${PROXY_DIR} already exists, skipping initialization."
        return
    fi

    info "Creating ${PROXY_DIR} from the template..."
    mkdir -p "${PROXY_DIR}/sites"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.Dockerfile"   "${PROXY_DIR}/nginx.Dockerfile"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.conf"         "${PROXY_DIR}/nginx.conf"
    cp "${SCRIPT_DIR}/nginxproxy/site-template.conf" "${PROXY_DIR}/site-template.conf"

    # Base proxy docker-compose.yml — without networks/volumes, they are added per site
    cat > "${PROXY_DIR}/docker-compose.yml" <<'DCEOF'
# cd /var/www/nginxproxy && docker compose up -d && docker restart nginxproxy
x-common-networks: &common-networks
  networks: []
services:
  nginxproxy:
    container_name: nginxproxy
    restart: always
    build:
      context: .
      dockerfile: nginx.Dockerfile
    # Reload the config every 6 hours to pick up renewed site certificates
    command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./sites:/etc/nginx/sites:ro
    <<: *common-networks
networks:
volumes:
DCEOF

    info "nginxproxy initialized in ${PROXY_DIR}"
}

# ==================== dhparam.pem creation ===================
create_dhparam() {
    local DHPARAM_FILE="${PROXY_DIR}/dhparam.pem"

    if [[ "$CREATE_DHPARAM" != true ]]; then
        return
    fi

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "File dhparam.pem already exists: ${DHPARAM_FILE}"
        return
    fi

    info "Creating dhparam.pem (this takes a few minutes)..."
    docker run --rm -v "${PROXY_DIR}:/output" alpine/openssl dhparam -out /output/dhparam.pem 2048

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "dhparam.pem created successfully: ${DHPARAM_FILE}"
    else
        error "Failed to create dhparam.pem"
    fi
}

# ==================== Argument parsing ====================
SLUG=""
DOMAIN=""
LARAVEL_VERSION="13.0"
PORT_HTTP=""
PORT_HTTPS=""
PORT_PHP=""
PORT_REDIS=""
REDIS_PASSWORD=""
DB_TYPE=""
PORT_MYSQL=""
PORT_POSTGRES=""
DB_MYSQL_NAME=""
DB_MYSQL_USER=""
DB_MYSQL_PASSWORD=""
DB_MYSQL_ROOT_PASSWORD=""
DB_POSTGRES_NAME=""
DB_POSTGRES_USER=""
DB_POSTGRES_PASSWORD=""
DB_NATIVE=false
DB_ROOT_PASSWORD=""
CREATE_DHPARAM=false
ENABLE_BASIC_AUTH=false
AUTH_USER=""
AUTH_PASSWORD=""
OBTAIN_SSL=true
SSL_EMAIL=""
ENDPOINT=""
INSTALL_FILAMENT=false
FILAMENT_EMAIL=""
FILAMENT_NAME=""
FILAMENT_PASSWORD=""
CREATE_BACKUP=false
BACKUP_FILE_PATH=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)                   SLUG="$2";                   shift 2 ;;
            --domain)                 DOMAIN="$2";                 shift 2 ;;
            --type)
                # Compatibility with calls from the old deploy.sh
                [[ "$2" == "$APP_TYPE" ]] || error "This script only deploys Laravel. For '$2' use deploy-$2.sh"
                shift 2 ;;
            --laravel-version)        LARAVEL_VERSION="$2";        shift 2 ;;
            --install-filament)       INSTALL_FILAMENT=true;       shift 1 ;;
            --filament-email)         FILAMENT_EMAIL="$2";         shift 2 ;;
            --filament-name)          FILAMENT_NAME="$2";          shift 2 ;;
            --filament-password)      FILAMENT_PASSWORD="$2";      shift 2 ;;
            --create-backup)          CREATE_BACKUP=true;          shift 1 ;;
            --port-http)              PORT_HTTP="$2";              shift 2 ;;
            --port-https)             PORT_HTTPS="$2";             shift 2 ;;
            --port-php)               PORT_PHP="$2";               shift 2 ;;
            --port-redis)             PORT_REDIS="$2";             shift 2 ;;
            --port-postgres)          PORT_POSTGRES="$2";          shift 2 ;;
            --port-mysql)             PORT_MYSQL="$2";             shift 2 ;;
            --redis-password)         REDIS_PASSWORD="$2";         shift 2 ;;
            --db-type)                DB_TYPE="$2";                shift 2 ;;
            --db-mysql-name)          DB_MYSQL_NAME="$2";          shift 2 ;;
            --db-mysql-user)          DB_MYSQL_USER="$2";          shift 2 ;;
            --db-mysql-password)      DB_MYSQL_PASSWORD="$2";      shift 2 ;;
            --db-mysql-root-password) DB_MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
            --db-postgres-name)       DB_POSTGRES_NAME="$2";       shift 2 ;;
            --db-postgres-user)       DB_POSTGRES_USER="$2";       shift 2 ;;
            --db-postgres-password)   DB_POSTGRES_PASSWORD="$2";   shift 2 ;;
            --db-native)              DB_NATIVE=true;              shift 1 ;;
            --db-root-password)       DB_ROOT_PASSWORD="$2";       shift 2 ;;
            --create-dhparam)         CREATE_DHPARAM=true;         shift 1 ;;
            --enable-basic-auth)      ENABLE_BASIC_AUTH=true;      shift 1 ;;
            --auth-user)              AUTH_USER="$2";              shift 2 ;;
            --auth-password)          AUTH_PASSWORD="$2";          shift 2 ;;
            --obtain-ssl)             OBTAIN_SSL=true;             shift 1 ;;
            --no-ssl)                 OBTAIN_SSL=false;            shift 1 ;;
            --ssl-email)              SSL_EMAIL="$2";              shift 2 ;;
            --endpoint)               ENDPOINT="$2";               shift 2 ;;
            *) error "Unknown argument: $1 (see --help)" ;;
        esac
    done

    [[ -z "$DOMAIN" ]]  && error "--domain is not specified"
    [[ -z "$DB_TYPE" ]] && error "--db-type is not specified"

    if [[ "$DB_TYPE" != "postgres" && "$DB_TYPE" != "mysql" ]]; then
        error "DB type must be 'postgres' or 'mysql', got: ${DB_TYPE}"
    fi

    # --- Check the root password for native MySQL ---
    if [[ "$DB_NATIVE" == true && "$DB_TYPE" == "mysql" && -z "$DB_ROOT_PASSWORD" ]]; then
        error "--db-root-password is required for a native MySQL database"
    fi

    if [[ "$OBTAIN_SSL" == true && -z "$SSL_EMAIL" ]]; then
        error "--ssl-email is required to obtain an SSL certificate"
    fi

    # --- Filament: validate before the installation starts, not after ---
    if [[ "$INSTALL_FILAMENT" == true && -z "$FILAMENT_EMAIL" ]]; then
        error "--filament-email is required to install Filament"
    fi

    # --- Generate slug if not given ---
    if [[ -z "$SLUG" ]]; then
        SLUG=$(generate_random_slug)
        DOMAIN="${SLUG}.${DOMAIN}"
        info "Generated slug: ${SLUG}"
        info "Domain updated: ${DOMAIN}"
    fi

    if ! [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        error "Invalid slug: ${SLUG} (letters, digits, '-' and '_' are allowed)"
    fi
    if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Invalid domain: ${DOMAIN}"
    fi

    # --- Validate Laravel version ---
    if ! [[ "$LARAVEL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        error "Invalid Laravel version format: ${LARAVEL_VERSION}. Expected X.Y (for example: 12.0)"
    fi
    local MAJOR_VERSION="${LARAVEL_VERSION%%.*}"
    if [[ $MAJOR_VERSION -lt 10 ]]; then
        error "Minimum supported Laravel version: 10.0, got: ${LARAVEL_VERSION}"
    fi
    info "Laravel version to be installed: ^${LARAVEL_VERSION}"

    # --- Generate Redis password if not given ---
    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD=$(generate_random_password)
        info "Generated Redis password: ${REDIS_PASSWORD}"
    fi

    # --- Generate MySQL credentials if not given ---
    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ -z "$DB_MYSQL_NAME" ]]; then
            DB_MYSQL_NAME=$(generate_random_name)
            info "Generated MySQL DB name: ${DB_MYSQL_NAME}"
        fi
        if [[ -z "$DB_MYSQL_USER" ]]; then
            DB_MYSQL_USER=$(generate_random_name)
            info "Generated MySQL user: ${DB_MYSQL_USER}"
        fi
        if [[ -z "$DB_MYSQL_PASSWORD" ]]; then
            DB_MYSQL_PASSWORD=$(generate_random_password)
            info "Generated MySQL password: ${DB_MYSQL_PASSWORD}"
        fi
        if [[ -z "$DB_MYSQL_ROOT_PASSWORD" ]]; then
            DB_MYSQL_ROOT_PASSWORD=$(generate_random_password)
            info "Generated MySQL root password: ${DB_MYSQL_ROOT_PASSWORD}"
        fi
    fi

    # --- Generate PostgreSQL credentials if not given ---
    if [[ "$DB_TYPE" == "postgres" ]]; then
        if [[ -z "$DB_POSTGRES_NAME" ]]; then
            DB_POSTGRES_NAME=$(generate_random_name)
            info "Generated PostgreSQL DB name: ${DB_POSTGRES_NAME}"
        fi
        if [[ -z "$DB_POSTGRES_USER" ]]; then
            DB_POSTGRES_USER=$(generate_random_name)
            info "Generated PostgreSQL user: ${DB_POSTGRES_USER}"
        fi
        if [[ -z "$DB_POSTGRES_PASSWORD" ]]; then
            DB_POSTGRES_PASSWORD=$(generate_random_password)
            info "Generated PostgreSQL password: ${DB_POSTGRES_PASSWORD}"
        fi
    fi

    # --- Generate Basic Auth credentials if not given ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        if [[ -z "$AUTH_USER" ]]; then
            AUTH_USER=$(generate_random_name)
            info "Generated Basic Auth user: ${AUTH_USER}"
        fi
        if [[ -z "$AUTH_PASSWORD" ]]; then
            AUTH_PASSWORD=$(generate_random_password)
            info "Generated Basic Auth password: ${AUTH_PASSWORD}"
        fi
    fi

    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        error "Template directory not found: ${TEMPLATE_DIR}"
    fi
}

# ==================== Port assignment ====================
# Manually specified ports are left unchanged; the rest are picked from the ranges
assign_ports() {
    info "Selecting free ports..."

    if [[ -z "$PORT_HTTP" ]]; then
        PORT_HTTP=$(find_free_port 8100 8400 "HTTP")
    fi
    info "  HTTP:       ${PORT_HTTP}"

    if [[ -z "$PORT_HTTPS" ]]; then
        PORT_HTTPS=$(find_free_port 4100 4300 "HTTPS")
    fi
    info "  HTTPS:      ${PORT_HTTPS}"

    if [[ -z "$PORT_PHP" ]]; then
        PORT_PHP=$(find_free_port 9100 9600 "PHP-FPM")
    fi
    info "  PHP-FPM:    ${PORT_PHP}"

    if [[ -z "$PORT_REDIS" ]]; then
        PORT_REDIS=$(find_free_port 6500 6800 "Redis")
    fi
    info "  Redis:      ${PORT_REDIS}"

    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_MYSQL="${PORT_MYSQL:-3306}"
            info "  MySQL:      ${PORT_MYSQL} (native DB)"
        else
            if [[ -z "$PORT_MYSQL" ]]; then
                PORT_MYSQL=$(find_free_port 3400 3600 "MySQL")
            fi
            info "  MySQL:      ${PORT_MYSQL}"
        fi
    else
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_POSTGRES="${PORT_POSTGRES:-5432}"
            info "  PostgreSQL: ${PORT_POSTGRES} (native DB)"
        else
            if [[ -z "$PORT_POSTGRES" ]]; then
                PORT_POSTGRES=$(find_free_port 5500 5800 "PostgreSQL")
            fi
            info "  PostgreSQL: ${PORT_POSTGRES}"
        fi
    fi
}

# ==================== DB setup in docker-compose.yml ======
# Removes the unused DB container (and the selected one for a native DB),
# their volumes and dependencies, and renames the selected DB to db / <slug>_db
configure_compose_db() {
    local COMPOSE_FILE="$1"

    if [[ "$DB_NATIVE" == true ]]; then
        info "Removing DB containers from docker-compose.yml (native DB in use)..."
    else
        info "Configuring docker-compose.yml for DB type ${DB_TYPE}..."
    fi

    python3 - "$COMPOSE_FILE" "$SLUG" "$DB_TYPE" "$DB_NATIVE" <<'PYEOF'
import re
import sys

path, slug, db_type, native = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'true'
other = 'mysql' if db_type == 'postgres' else 'postgres'

drop_services = {f'db_{other}'}
drop_volumes = {f'{slug}_db_{other}'}
if native:
    drop_services.add(f'db_{db_type}')
    drop_volumes.add(f'{slug}_db_{db_type}')

with open(path) as f:
    lines = f.read().splitlines()

# --- 1. Remove service and volume blocks ---
result = []
section = None
skipping = False
for line in lines:
    top = re.match(r'^([A-Za-z][\w-]*):', line)
    if top:
        section = top.group(1)
        skipping = False
        result.append(line)
        continue

    key = re.match(r'^  ([\w.-]+):\s*$', line)
    if key:
        name = key.group(1)
        skipping = (section == 'services' and name in drop_services) or \
                   (section == 'volumes' and name in drop_volumes)
        if not skipping:
            result.append(line)
        continue

    if skipping:
        # Inside a removed block: blank lines and everything indented more than 2
        if line.strip() == '' or len(line) - len(line.lstrip()) > 2:
            continue
        skipping = False

    result.append(line)

# --- 2. Native DB: remove dependencies on the DB container ---
if native:
    db_names = {'db', 'db_postgres', 'db_mysql'}
    cleaned = []
    i = 0
    while i < len(result):
        line = result[i]
        if line.strip() == 'depends_on:':
            indent = len(line) - len(line.lstrip())
            items = []
            i += 1
            while i < len(result) and re.match(r'^\s+-\s+', result[i]) \
                    and len(result[i]) - len(result[i].lstrip()) > indent:
                if result[i].strip()[1:].strip() not in db_names:
                    items.append(result[i])
                i += 1
            if items:
                cleaned.append(line)
                cleaned.extend(items)
            continue
        cleaned.append(line)
        i += 1
    result = cleaned

# --- 3. Rename the selected DB: db_postgres → db, <slug>_db_postgres → <slug>_db ---
result = [re.sub(rf'\bdb_{db_type}\b', 'db', l.replace(f'{slug}_db_{db_type}', f'{slug}_db'))
          for l in result]

with open(path, 'w') as f:
    f.write('\n'.join(result) + '\n')
PYEOF
}

# ==================== Project .env generation ======================
write_project_env() {
    local ENV_FILE="${PROJECT_DIR}/.env"

    info "Generating .env for ${SLUG}..."
    {
        echo "SITE_HOST=${DOMAIN}"
        echo "SITE_PORT_HTTP=${PORT_HTTP}"
        echo "SITE_PORT_HTTPS=${PORT_HTTPS}"
        echo ""
        echo "PHP_PORT=${PORT_PHP}"
        echo ""
        echo "REDIS_PORT=${PORT_REDIS}"
        echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
        echo ""
        if [[ "$DB_TYPE" == "postgres" ]]; then
            echo "DB_PORT=${PORT_POSTGRES}"
            echo "DB_POSTGRES_NAME=${DB_POSTGRES_NAME}"
            echo "DB_POSTGRES_USER=${DB_POSTGRES_USER}"
            echo "DB_POSTGRES_PASSWORD=${DB_POSTGRES_PASSWORD}"
        else
            echo "DB_PORT=${PORT_MYSQL}"
            echo "DB_MYSQL_NAME=${DB_MYSQL_NAME}"
            echo "DB_MYSQL_USER=${DB_MYSQL_USER}"
            echo "DB_MYSQL_PASSWORD=${DB_MYSQL_PASSWORD}"
            echo "DB_MYSQL_PASSWORD_ROOT=${DB_MYSQL_ROOT_PASSWORD}"
        fi
        echo ""
        echo "DB_NATIVE=${DB_NATIVE}"
        if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
            echo ""
            echo "AUTH_USER=${AUTH_USER}"
            echo "AUTH_PASSWORD=${AUTH_PASSWORD}"
        fi
    } > "$ENV_FILE"
}

# ==================== Project creation ======================
create_project() {
    PROJECT_DIR="${WWW_DIR}/${SLUG}"

    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Project directory already exists: ${PROJECT_DIR}"

        # Check whether the project containers are running
        info "Checking for project containers..."

        local RUNNING_CONTAINERS
        local ALL_CONTAINERS
        RUNNING_CONTAINERS=$(docker ps -q --filter "name=${SLUG}_" 2>/dev/null | wc -l)
        ALL_CONTAINERS=$(docker ps -aq --filter "name=${SLUG}_" 2>/dev/null | wc -l)

        if [[ $ALL_CONTAINERS -eq 0 ]]; then
            warn "No project containers found. Removing the project directory..."
        else
            if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
                warn "Project containers are running ($RUNNING_CONTAINERS of $ALL_CONTAINERS). Stopping..."
                cd "$PROJECT_DIR" || error "Failed to change to ${PROJECT_DIR}"
                docker compose down
                cd "${SCRIPT_DIR}" || true
                info "Containers stopped"
            fi
            warn "Removing the project directory..."
        fi
        rm -rf "$PROJECT_DIR"
        info "Project directory removed. Continuing creation..."
    fi

    info "Creating project ${SLUG} (${APP_TYPE}) in ${PROJECT_DIR}..."
    mkdir -p "${PROJECT_DIR}"

    # Copy the entire template contents
    cp -a "${TEMPLATE_DIR}/." "${PROJECT_DIR}/"

    # --- Organize Dockerfiles into subfolders ---
    if [[ -d "${PROJECT_DIR}/.docker" ]]; then
        mkdir -p "${PROJECT_DIR}/.docker/php"
        mkdir -p "${PROJECT_DIR}/.docker/nginx"
        mkdir -p "${PROJECT_DIR}/.docker/init/postgres"

        if ls "${PROJECT_DIR}/.docker"/php*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/php*.Dockerfile "${PROJECT_DIR}/.docker/php/" 2>/dev/null || true
        fi
        if ls "${PROJECT_DIR}/.docker"/nginx*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/nginx*.Dockerfile "${PROJECT_DIR}/.docker/nginx/" 2>/dev/null || true
        fi
    fi

    # --- public_html: composer runs in the PHP image as user www (uid 1000) ---
    mkdir -p "${PROJECT_DIR}/public_html"
    chown 1000:1000 "${PROJECT_DIR}/public_html"

    # --- Replace {SLUG} → slug in docker-compose.yml ---
    sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/docker-compose.yml"

    # --- DB container: selected type or native DB ---
    configure_compose_db "${PROJECT_DIR}/docker-compose.yml"

    # --- Project .env ---
    write_project_env

    # --- Replace MYSITE.COM → domain in _site.conf ---
    if [[ -f "${PROJECT_DIR}/.config/nginx/_site.conf" ]]; then
        sed -i "s/MYSITE\.COM/${DOMAIN}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
        sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Uncomment dhparam.pem in docker-compose.yml and _site.conf ---
    if [[ "$CREATE_DHPARAM" == true ]]; then
        info "Uncommenting the dhparam.pem line in docker-compose.yml..."
        # The project is in /var/www/<slug>, the proxy in /var/www/nginxproxy, i.e. the path is ../nginxproxy
        sed -i 's|^\s*#\s*-\s*\(\.\./\)\{1,2\}nginxproxy/dhparam\.pem:/etc/ssl/certs/dhparam\.pem.*|      - ../nginxproxy/dhparam.pem:/etc/ssl/certs/dhparam.pem:ro|' "${PROJECT_DIR}/docker-compose.yml"

        info "Uncommenting the ssl_dhparam line in _site.conf..."
        sed -i 's|^\s*#ssl_dhparam /etc/ssl/certs/dhparam\.pem;|        ssl_dhparam /etc/ssl/certs/dhparam.pem;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Create .htpasswd for Basic Auth ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        info "Creating .htpasswd file for Basic Authentication..."
        mkdir -p "${PROJECT_DIR}/.config/nginx"
        docker run --rm httpd:alpine htpasswd -nb "${AUTH_USER}" "${AUTH_PASSWORD}" > "${PROJECT_DIR}/.config/nginx/.htpasswd"

        if [[ -s "${PROJECT_DIR}/.config/nginx/.htpasswd" ]]; then
            info ".htpasswd file created: ${PROJECT_DIR}/.config/nginx/.htpasswd"

            info "Uncommenting the .htpasswd line in docker-compose.yml..."
            sed -i 's|^\s*#\s*-\s*\./.config/nginx/\.htpasswd:/etc/nginx/\.htpasswd:ro|      - ./.config/nginx/.htpasswd:/etc/nginx/.htpasswd:ro|' "${PROJECT_DIR}/docker-compose.yml"

            info "Uncommenting the Basic Auth lines in _site.conf..."
            sed -i 's|^#\s*auth_basic "Restricted Access";|            auth_basic "Restricted Access";|' "${PROJECT_DIR}/.config/nginx/_site.conf"
            sed -i 's|^#\s*auth_basic_user_file /etc/nginx/\.htpasswd;|            auth_basic_user_file /etc/nginx/.htpasswd;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
        else
            error "Failed to create .htpasswd file"
        fi
    fi

    info "Project ${SLUG} created in ${PROJECT_DIR}"
}

# ==================== Site config creation for nginxproxy ======
update_proxy_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"
    local TEMPLATE="${PROXY_DIR}/site-template.conf"

    mkdir -p "${PROXY_DIR}/sites"

    # Copy the template if it is missing
    if [[ ! -f "$TEMPLATE" ]]; then
        info "Copying site-template.conf to nginxproxy..."
        local SOURCE_TEMPLATE="${SCRIPT_DIR}/nginxproxy/site-template.conf"

        if [[ ! -f "$SOURCE_TEMPLATE" ]]; then
            error "Template not found: ${SOURCE_TEMPLATE}. SCRIPT_DIR=${SCRIPT_DIR}"
        fi

        cp "$SOURCE_TEMPLATE" "$TEMPLATE"
    fi

    # Check whether the sites folder is mounted in docker-compose.yml
    if ! grep -q "./sites:/etc/nginx/sites:ro" "${PROXY_DIR}/docker-compose.yml"; then
        info "Adding the sites folder mount to the nginxproxy docker-compose.yml..."
        sed -i '/- \.\/nginx\.conf:\/etc\/nginx\/nginx\.conf:ro/a\      - ./sites:/etc/nginx/sites:ro' "${PROXY_DIR}/docker-compose.yml"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        warn "Config ${SITE_CONF} already exists, skipping."
        return
    fi

    info "Creating config ${SLUG}.conf from the template..."
    sed -e "s/SLUG/${SLUG}/g" \
        -e "s/DOMAIN/${DOMAIN}/g" \
        "$TEMPLATE" > "$SITE_CONF"

    info "Config ${SLUG}.conf created in ${PROXY_DIR}/sites/"
}

# ==================== Update nginxproxy/docker-compose.yml
update_proxy_docker_compose() {
    local DC="${PROXY_DIR}/docker-compose.yml"

    # Check whether this slug is already in the networks section
    if grep -q "^  ${SLUG}:$" "$DC"; then
        info "Network ${SLUG} is already added to ${DC}"
        return
    fi

    info "Adding ${SLUG} to ${DC}..."

    python3 - "$DC" "$SLUG" <<'PYEOF'
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

dc_path = sys.argv[1]
slug = sys.argv[2]

with open(dc_path) as f:
    content = f.read()

lines = content.splitlines()
result = []
i = 0

# Collect existing keys to check for duplicates
existing_networks = set()
existing_volumes = set()
existing_network_refs = set()
existing_volume_mounts = set()

for line in lines:
    # Networks in x-common-networks
    match = re.match(r'^\s+-\s+([\w-]+)$', line)
    if match:
        existing_network_refs.add(match.group(1))
    # Top-level networks
    match = re.match(r'^\s{2}([\w-]+):\s*$', line)
    if match:
        existing_networks.add(match.group(1))
    # Top-level volumes
    match = re.match(r'^\s{2}([\w-]+_ssl_certificates):\s*$', line)
    if match:
        existing_volumes.add(match.group(1))
    # Volume mounts in the service
    match = re.match(r'^\s+-\s+([\w-]+_ssl_certificates):/etc/letsencrypt/', line)
    if match:
        existing_volume_mounts.add(match.group(1))

while i < len(lines):
    line = lines[i]

    # --- x-common-networks: add the network to the list ---
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        if line.strip() == "networks: []":
            # Replace the inline syntax with a multi-line one containing the new network
            result.append("  networks:")
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
            i += 1
        else:
            result.append(line)
            i += 1
            while i < len(lines) and lines[i].strip().startswith("-"):
                result.append(lines[i])
                i += 1
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
        continue

    # --- volumes: in the nginxproxy service — add the ssl volume ---
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volume_mounts:
            result.append(f"      - {volume_key}:/etc/letsencrypt/{slug}")
        continue

    # --- networks: top level ---
    if re.match(r'^networks:\s*(\{\})?$', line):
        result.append("networks:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        if slug not in existing_networks:
            result.append(f"  {slug}:")
            result.append(f"    name: {slug}")
            result.append(f"    external: true")
        continue

    # --- volumes: top level ---
    if re.match(r'^volumes:\s*(\{\})?$', line):
        result.append("volumes:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volumes:
            result.append(f"  {volume_key}:")
            result.append(f"    name: {volume_key}")
            result.append(f"    external: true")
        continue

    result.append(line)
    i += 1

with open(dc_path, 'w') as f:
    f.write("\n".join(result) + "\n")
PYEOF

    info "${SLUG} added to the proxy docker-compose.yml"
}

# ==================== Commenting / uncommenting SSL blocks ==============
# toggle_ssl_blocks comment|uncomment
# Works on the "listen 443" server block in the project _site.conf and in nginxproxy/sites/<slug>.conf
toggle_ssl_blocks() {
    local MODE="$1"
    local FILES=()
    local FILE

    for FILE in "${PROJECT_DIR}/.config/nginx/_site.conf" "${PROXY_DIR}/sites/${SLUG}.conf"; do
        [[ -f "$FILE" ]] && FILES+=("$FILE")
    done
    [[ ${#FILES[@]} -eq 0 ]] && return 0

    python3 - "$MODE" "${FILES[@]}" <<'PYEOF'
import sys
import re

mode, paths = sys.argv[1], sys.argv[2:]

for conf_path in paths:
    with open(conf_path) as f:
        lines = f.read().splitlines()

    result = []
    in_ssl_block = False
    brace_count = 0

    for idx, line in enumerate(lines):
        if not in_ssl_block:
            window = lines[idx:idx + 10]
            if mode == 'comment':
                starts = re.match(r'^\s*server\s*\{', line) and any('listen 443' in l for l in window)
            else:
                starts = re.match(r'^#\s*server\s*\{', line) and \
                    any(l.startswith('#') and 'listen 443' in l for l in window)
            if starts:
                in_ssl_block = True
                brace_count = 1
                result.append('#' + line if mode == 'comment' else line[1:])
            else:
                result.append(line)
            continue

        if mode == 'comment':
            body = line
            result.append('#' + line)
        else:
            body = line[1:] if line.startswith('#') else line
            result.append(body)

        brace_count += body.count('{') - body.count('}')
        if brace_count == 0:
            in_ssl_block = False

    with open(conf_path, 'w') as f:
        f.write('\n'.join(result) + '\n')
PYEOF

    for FILE in "${FILES[@]}"; do
        if [[ "$MODE" == "comment" ]]; then
            info "SSL block commented out in ${FILE}"
        else
            info "SSL block uncommented in ${FILE}"
        fi
    done
}

comment_ssl_blocks() {
    info "Commenting out SSL blocks until the certificate is obtained..."
    toggle_ssl_blocks comment
}

uncomment_ssl_blocks() {
    info "Uncommenting SSL blocks after the certificate is obtained..."
    toggle_ssl_blocks uncomment
}

# ==================== Native database creation ==============
create_native_database() {
    if [[ "$DB_NATIVE" != true ]]; then
        return
    fi

    info "Creating native ${DB_TYPE} database..."

    if [[ "$DB_TYPE" == "postgres" ]]; then
        if ! command -v psql &> /dev/null; then
            error "PostgreSQL is not installed on the server. Install PostgreSQL or use a containerized DB (remove the --db-native flag)"
        fi

        if ! sudo -u postgres psql -c "SELECT 1;" &> /dev/null; then
            error "PostgreSQL server is not running or unavailable. Start PostgreSQL: sudo systemctl start postgresql"
        fi

        info "Creating PostgreSQL user: ${DB_POSTGRES_USER}"
        sudo -u postgres psql -c "CREATE USER \"${DB_POSTGRES_USER}\" WITH PASSWORD '${DB_POSTGRES_PASSWORD}';" 2>/dev/null || \
            warn "User ${DB_POSTGRES_USER} already exists"

        info "Creating PostgreSQL database: ${DB_POSTGRES_NAME}"
        sudo -u postgres psql -c "CREATE DATABASE \"${DB_POSTGRES_NAME}\" OWNER \"${DB_POSTGRES_USER}\";" 2>/dev/null || \
            warn "Database ${DB_POSTGRES_NAME} already exists"

        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_POSTGRES_NAME}\" TO \"${DB_POSTGRES_USER}\";"

        success "PostgreSQL database ${DB_POSTGRES_NAME} created"

    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if ! command -v mysql &> /dev/null; then
            error "MySQL is not installed on the server. Install MySQL or use a containerized DB (remove the --db-native flag)"
        fi

        if ! mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &> /dev/null; then
            error "MySQL server is unavailable or the root password is wrong. Check: 1) MySQL is running (sudo systemctl start mysql), 2) --db-root-password is correct"
        fi

        info "Creating MySQL database: ${DB_MYSQL_NAME}"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_MYSQL_NAME}\`;" || \
            error "Failed to create MySQL database. Check the root password."

        # The application connects from a container (via the Docker bridge), not from localhost
        info "Creating MySQL user: ${DB_MYSQL_USER}"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_MYSQL_USER}'@'%' IDENTIFIED BY '${DB_MYSQL_PASSWORD}';"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_MYSQL_NAME}\`.* TO '${DB_MYSQL_USER}'@'%';"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

        success "MySQL database ${DB_MYSQL_NAME} created"
    fi
}

# ==================== Docker build and start ==============
build_and_start_project() {
    info "Building and starting the project Docker containers..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    # Create the external network if it does not exist
    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        info "Creating external network ${SLUG}..."
        if docker network create "${SLUG}" \
            --label "com.docker.compose.project=${SLUG}" \
            --label "com.docker.compose.network=${SLUG}"; then
            info "Network ${SLUG} created successfully"
        else
            error "Failed to create network ${SLUG}"
        fi
    else
        info "Network ${SLUG} already exists"
    fi

    info "Checking and creating required volumes..."
    local VOLUMES=("${SLUG}_ssl_certificates" "${SLUG}_certbot_www" "${SLUG}_redis_data")
    if [[ "$DB_NATIVE" != true ]]; then
        VOLUMES=("${SLUG}_db" "${VOLUMES[@]}")
    fi

    local VOLUME
    for VOLUME in "${VOLUMES[@]}"; do
        if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
            info "Creating volume ${VOLUME}..."
            docker volume create "${VOLUME}"
        else
            info "Volume ${VOLUME} already exists"
        fi
    done

    info "Running: docker compose up -d --build"
    if ! docker compose up -d --build; then
        error "Failed to build/start the project. Check the logs: cd ${PROJECT_DIR} && docker compose logs"
    fi

    info "docker compose command completed successfully"

    # Give the containers time to start
    info "Waiting for containers to start..."
    sleep 10

    info "Checking container status..."
    local RUNNING
    local ALL
    RUNNING=$(docker ps --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)
    ALL=$(docker ps -a --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)

    info "Running containers: ${RUNNING} of ${ALL}"

    if [[ $RUNNING -eq 0 ]]; then
        warn "No containers are running! Check the logs:"
        warn "  cd ${PROJECT_DIR} && docker compose logs"
    else
        info "Container status:"
        docker ps -a --filter "name=${SLUG}_" --format "table {{.Names}}\t{{.Status}}"

        # Check the critical containers (php, nginx, db)
        local CRITICAL_RUNNING
        CRITICAL_RUNNING=$(docker ps --filter "name=${SLUG}_php" --filter "name=${SLUG}_nginx" --filter "name=${SLUG}_db" --format "{{.Names}}" | wc -l)
        if [[ $CRITICAL_RUNNING -ge 2 ]]; then
            info "Main containers (php, nginx, db) are running"
        else
            warn "Some critical containers failed to start. Check the logs."
        fi
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Laravel installation via composer ==============
install_laravel() {
    info "Installing Laravel version ^${LARAVEL_VERSION}..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    # Check whether Laravel is already installed (artisan present)
    if [[ -f "${PROJECT_DIR}/public_html/artisan" ]]; then
        warn "Laravel is already installed in ${PROJECT_DIR}/public_html/"
        info "Skipping Laravel installation"
        cd "${SCRIPT_DIR}" || true
        return
    fi

    info "Running: docker compose run --rm composer create-project laravel/laravel:^${LARAVEL_VERSION} ."

    if docker compose run --rm composer create-project "laravel/laravel:^${LARAVEL_VERSION}" .; then
        success "Laravel ^${LARAVEL_VERSION} installed successfully!"

        info "Setting permissions..."
        docker compose run --rm permissions

        info "Laravel is ready to use in ${PROJECT_DIR}/public_html/"
    else
        error "Failed to install Laravel. Check the logs above."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Laravel .env configuration ==============
configure_laravel_env() {
    local LARAVEL_ENV="${PROJECT_DIR}/public_html/.env"

    if [[ ! -f "$LARAVEL_ENV" ]]; then
        warn "Laravel .env file not found: ${LARAVEL_ENV}"
        info "Skipping Laravel .env configuration"
        return
    fi

    info "Configuring the Laravel .env file..."

    local DB_CONNECTION=""
    local DB_HOST=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""
    local DB_PORT_VALUE=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_CONNECTION="pgsql"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_CONNECTION="mysql"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    # Native DB: Docker bridge IP and the port on the host.
    # Containerized DB: container name and internal port (the external port from .env is not listened on inside the network)
    if [[ "$DB_NATIVE" == true ]]; then
        DB_HOST="172.17.0.1"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="$PORT_POSTGRES"; else DB_PORT_VALUE="$PORT_MYSQL"; fi
    else
        DB_HOST="${SLUG}_db"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="5432"; else DB_PORT_VALUE="3306"; fi
    fi

    # Laravel 11+ keeps DB_* commented out, Laravel 10 does not; handle both cases
    sed -i "s|^#\? *DB_CONNECTION=.*|DB_CONNECTION=${DB_CONNECTION}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_HOST=.*|DB_HOST=${DB_HOST}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_PORT=.*|DB_PORT=${DB_PORT_VALUE}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_DATABASE=.*|DB_DATABASE=$(sed_escape "$DB_NAME")|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_USERNAME=.*|DB_USERNAME=$(sed_escape "$DB_USER")|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_PASSWORD=.*|DB_PASSWORD=$(sed_escape "$DB_PASS")|" "$LARAVEL_ENV"

    sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" "$LARAVEL_ENV"

    info "DB parameters and APP_URL written successfully to ${LARAVEL_ENV}:"
    info "  APP_URL: https://${DOMAIN}"
    info "  DB_CONNECTION: ${DB_CONNECTION}"
    info "  DB_HOST: ${DB_HOST}"
    info "  DB_PORT: ${DB_PORT_VALUE}"
    info "  DB_DATABASE: ${DB_NAME}"
    info "  DB_USERNAME: ${DB_USER}"

    info "Running Laravel migrations..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    if docker compose run --rm artisan migrate --force 2>&1; then
        success "Laravel migrations completed successfully"
    else
        warn "Failed to run Laravel migrations. Check the DB connection and run the migrations manually:"
        warn "  cd ${PROJECT_DIR} && docker compose run --rm artisan migrate"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Laravel Filament installation ==============
install_filament() {
    if [[ "$INSTALL_FILAMENT" != true ]]; then
        return
    fi

    info "Installing Laravel Filament..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    # Generate a random name if not given (8 characters)
    if [[ -z "$FILAMENT_NAME" ]]; then
        FILAMENT_NAME=$(random_string 'a-f0-9' 8)
        info "Generated random user name: ${FILAMENT_NAME}"
    fi

    # Generate a random password if not given (10 characters)
    if [[ -z "$FILAMENT_PASSWORD" ]]; then
        FILAMENT_PASSWORD=$(random_string 'a-zA-Z0-9' 10)
        info "Generated random password: ${FILAMENT_PASSWORD}"
    fi

    info "Step 1/3: Installing the Filament package..."
    if docker compose run --rm composer require filament/filament:"^5.0" 2>&1; then
        success "Filament package installed successfully"
    else
        error "Failed to install the Filament package"
    fi

    info "Step 2/3: Installing the Filament panel..."
    if docker compose run --rm artisan filament:install --panels 2>&1; then
        success "Filament panel installed successfully"
    else
        error "Failed to install the Filament panel"
    fi

    info "Step 3/3: Creating the Filament user..."
    if docker compose run --rm artisan make:filament-user --name="${FILAMENT_NAME}" --email="${FILAMENT_EMAIL}" --password="${FILAMENT_PASSWORD}" 2>&1; then
        success "Filament user created successfully"
        info "Filament login credentials:"
        info "  Email: ${FILAMENT_EMAIL}"
        info "  Name: ${FILAMENT_NAME}"
        info "  Password: ${FILAMENT_PASSWORD}"
        info "  URL: https://${DOMAIN}/admin"

        local GLOBAL_ENV="${PROJECT_DIR}/.env"
        if [[ -f "$GLOBAL_ENV" ]]; then
            info "Saving Filament credentials to the global .env file..."
            {
                echo ""
                echo "# Filament Admin Credentials"
                echo "FILAMENT_ADMIN_NAME=${FILAMENT_NAME}"
                echo "FILAMENT_ADMIN_EMAIL=${FILAMENT_EMAIL}"
                echo "FILAMENT_ADMIN_PASSWORD=${FILAMENT_PASSWORD}"
            } >> "$GLOBAL_ENV"
            success "Filament credentials saved to ${GLOBAL_ENV}"
        fi
    else
        error "Failed to create the Filament user"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== SSL certificate issuance ===========
obtain_ssl_certificate() {
    if [[ "$OBTAIN_SSL" != true ]]; then
        info "Skipping SSL certificate issuance (--no-ssl given)"
        return
    fi

    info "Obtaining an SSL certificate for domain ${DOMAIN}..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    # A certbot failure must not abort the script (set -e) — summary, endpoint and backup still follow
    if docker compose run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        -d "${DOMAIN}" \
        --email "${SSL_EMAIL}" \
        --agree-tos \
        --non-interactive; then
        info "SSL certificate obtained successfully for ${DOMAIN}!"

        uncomment_ssl_blocks

        info "Restarting the project nginx to apply the SSL configuration..."
        docker compose restart nginx

        info "Restarting nginxproxy to apply the SSL configuration..."
        cd "${PROXY_DIR}" || error "Failed to change to ${PROXY_DIR}"
        docker compose restart

        info "SSL configuration applied successfully!"
    else
        warn "Failed to obtain an SSL certificate. Check:"
        warn "  - DNS records for ${DOMAIN} point to this server"
        warn "  - Ports 80 and 443 are open and reachable"
        warn "  - nginxproxy is up and running"
        warn "  - the project nginx is working correctly"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== nginxproxy restart ===================
restart_nginxproxy() {
    info "Restarting nginxproxy to apply the changes..."
    cd "${PROXY_DIR}" || error "Failed to change to ${PROXY_DIR}"

    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        warn "Network ${SLUG} not found. Skipping nginxproxy restart."
        warn "Restart nginxproxy manually after the project starts:"
        warn "  cd ${PROXY_DIR} && docker compose up -d"
        cd "${SCRIPT_DIR}" || true
        return
    fi

    if docker compose up -d; then
        info "nginxproxy restarted successfully"

        sleep 3

        if docker ps --filter "name=nginxproxy" --format "{{.Names}}" | grep -q "nginxproxy"; then
            info "nginxproxy is running"
        else
            warn "nginxproxy is not running. Check the logs:"
            warn "  cd ${PROXY_DIR} && docker compose logs"
        fi
    else
        warn "Problems occurred while restarting nginxproxy. Check the configuration."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Send project data to the endpoint ====================
send_project_data() {
    if [[ -z "$ENDPOINT" ]]; then
        return
    fi

    info "Sending project data to endpoint: ${ENDPOINT}..."

    local DB_PORT_VALUE=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_PORT_VALUE="$PORT_POSTGRES"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_PORT_VALUE="$PORT_MYSQL"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    local JSON_DATA
    JSON_DATA=$(cat <<JSONEOF
{
  "slug": "${SLUG}",
  "domain": "${DOMAIN}",
  "app_type": "${APP_TYPE}",
  "laravel_version": "${LARAVEL_VERSION}",
  "db_type": "${DB_TYPE}",
  "ports": {
    "http": ${PORT_HTTP},
    "https": ${PORT_HTTPS},
    "php": ${PORT_PHP},
    "redis": ${PORT_REDIS}
  },
  "redis": {
    "password": "${REDIS_PASSWORD}"
  },
  "database": {
    "type": "${DB_TYPE}",
    "port": ${DB_PORT_VALUE},
    "name": "${DB_NAME}",
    "user": "${DB_USER}",
    "password": "${DB_PASS}"
  },
  "basic_auth": {
    "enabled": ${ENABLE_BASIC_AUTH},
    "user": "${AUTH_USER}",
    "password": "${AUTH_PASSWORD}"
  },
  "ssl": {
    "enabled": ${OBTAIN_SSL},
    "email": "${SSL_EMAIL}"
  },
  "project_path": "${WWW_DIR}/${SLUG}"
}
JSONEOF
)

    local RESPONSE
    RESPONSE=$(curl -X PUT \
        -H "Content-Type: application/json" \
        -d "${JSON_DATA}" \
        -w "\n%{http_code}" \
        -s \
        "${ENDPOINT}" 2>&1) || true

    local HTTP_CODE
    local RESPONSE_BODY
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        success "Data sent to the endpoint successfully (HTTP ${HTTP_CODE})"
        if [[ -n "$RESPONSE_BODY" ]]; then
            info "Server response: ${RESPONSE_BODY}"
        fi
    else
        warn "Failed to send data to the endpoint (HTTP ${HTTP_CODE})"
        if [[ -n "$RESPONSE_BODY" ]]; then
            warn "Server response: ${RESPONSE_BODY}"
        fi
    fi
}

# ==================== Project backup archive creation ====================
create_project_backup() {
    if [[ "$CREATE_BACKUP" != true ]]; then
        return
    fi

    info "Creating a project backup archive..."

    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_PATH="/tmp/${SLUG}_${TIMESTAMP}.zip"

    ensure_packages zip

    info "Archiving ${PROJECT_DIR} to ${BACKUP_PATH}..."
    cd "$(dirname "${PROJECT_DIR}")" || error "Failed to change to the parent directory"

    if zip -r -q "${BACKUP_PATH}" "$(basename "${PROJECT_DIR}")"; then
        local BACKUP_SIZE
        BACKUP_SIZE=$(du -h "${BACKUP_PATH}" | cut -f1)
        BACKUP_FILE_PATH="${BACKUP_PATH}"
        success "Backup archive created successfully: ${BACKUP_PATH}"
        info "Archive size: ${BACKUP_SIZE}"

        info "Saving the backup archive path to the .env file..."
        {
            echo ""
            echo "# Backup Archive"
            echo "BACKUP_ARCHIVE_PATH=${BACKUP_PATH}"
        } >> "${PROJECT_DIR}/.env"
    else
        error "Failed to create the backup archive"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Summary output ====================
print_summary() {
    echo ""
    echo "============================================================"
    info "Deployment completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT:"
    echo "  Slug:           ${SLUG}"
    echo "  Domain:         ${DOMAIN}"
    echo "  Type:           ${APP_TYPE}"
    echo "  Laravel:        ^${LARAVEL_VERSION}"
    echo "  DB Type:        ${DB_TYPE}$([[ "$DB_NATIVE" == true ]] && echo " (native)")"
    echo "  Project Path:   ${WWW_DIR}/${SLUG}"
    echo "  .env:           ${WWW_DIR}/${SLUG}/.env"
    echo ""
    echo "PORTS:"
    echo "  HTTP:           ${PORT_HTTP}"
    echo "  HTTPS:          ${PORT_HTTPS}"
    echo "  PHP-FPM:        ${PORT_PHP}"
    echo "  Redis:          ${PORT_REDIS}"
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "  MySQL:          ${PORT_MYSQL}"
    else
        echo "  PostgreSQL:     ${PORT_POSTGRES}"
    fi
    echo ""
    echo "REDIS:"
    echo "  Password:       ${REDIS_PASSWORD}"
    echo ""
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "MYSQL:"
        echo "  Database:       ${DB_MYSQL_NAME}"
        echo "  User:           ${DB_MYSQL_USER}"
        echo "  Password:       ${DB_MYSQL_PASSWORD}"
        echo "  Root Password:  ${DB_MYSQL_ROOT_PASSWORD}"
    else
        echo "POSTGRESQL:"
        echo "  Database:       ${DB_POSTGRES_NAME}"
        echo "  User:           ${DB_POSTGRES_USER}"
        echo "  Password:       ${DB_POSTGRES_PASSWORD}"
    fi
    echo ""
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        echo "HTTP BASIC AUTHENTICATION:"
        echo "  User:           ${AUTH_USER}"
        echo "  Password:       ${AUTH_PASSWORD}"
        echo "  .htpasswd:      ${WWW_DIR}/${SLUG}/.config/nginx/.htpasswd"
        echo ""
    fi
    if [[ "$INSTALL_FILAMENT" == true ]]; then
        echo "FILAMENT:"
        echo "  URL:            https://${DOMAIN}/admin"
        echo "  Name:           ${FILAMENT_NAME}"
        echo "  Email:          ${FILAMENT_EMAIL}"
        echo "  Password:       ${FILAMENT_PASSWORD}"
        echo ""
    fi
    echo "============================================================"
    echo "Next steps:"
    echo "============================================================"
    if [[ "$OBTAIN_SSL" == true ]]; then
        echo "  1. Restart the proxy to apply the SSL certificate:"
        echo "       cd ${PROXY_DIR} && docker compose restart"
        echo ""
        echo "  2. Check that the site is reachable:"
        echo "       https://${DOMAIN}"
    else
        echo "  1. Restart the proxy:"
        echo "       cd ${PROXY_DIR} && docker compose up -d && docker restart nginxproxy"
        echo ""
        echo "  2. Obtain the SSL certificate manually:"
        echo "       cd ${WWW_DIR}/${SLUG} && docker compose run --rm certbot certonly \\"
        echo "         --webroot -w /var/www/certbot -d ${DOMAIN} \\"
        echo "         --email YOUR_EMAIL --agree-tos --non-interactive"
    fi
    echo ""
    echo "  Check the container status:"
    echo "       cd ${WWW_DIR}/${SLUG} && docker compose ps"
    echo ""

    if [[ -n "$BACKUP_FILE_PATH" ]]; then
        echo "BACKUP:"
        echo "  Project archive: ${BACKUP_FILE_PATH}"
        echo ""
    fi

    echo "============================================================"
    echo ""
}

# ==================== MAIN ==================================
main() {
    local ARG
    for ARG in "$@"; do
        case "$ARG" in -h|--help) usage; exit 0 ;; esac
    done

    check_root
    ensure_www_dir
    info "Parsing arguments..."
    parse_args "$@"
    assign_ports
    info "Arguments processed successfully"
    install_docker
    init_nginxproxy
    create_dhparam
    create_project
    update_proxy_nginx_conf
    update_proxy_docker_compose
    comment_ssl_blocks
    create_native_database
    build_and_start_project
    install_laravel
    configure_laravel_env
    install_filament
    restart_nginxproxy
    obtain_ssl_certificate
    send_project_data
    create_project_backup
    print_summary
}

main "$@"
