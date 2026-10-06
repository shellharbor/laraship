#!/bin/bash
# SC2034 (unused variable) is disabled for the whole file: FILAMENT_* and other settings are read by modules/*.sh
# shellcheck disable=SC2034
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
# Settings can also come from a file (command-line flags override it):
#   sudo bash deploy-laravel.sh --config /root/shop.conf
#   --config FILE                KEY=VALUE file; the key is the flag in upper case (DB_TYPE = --db-type),
#                                see examples/deploy.config.example. Versions live in versions.env
#   --preset NAME                Apply a preset from presets/ (repeatable); --list-presets shows them.
#                                Order: presets, then --config, then command-line flags (later wins)
#   --dry-run                    Print the effective settings (no secrets) and exit: changes nothing, no root needed
#   --version, -V                Print the version and exit
#
# Required arguments:
#   --domain DOMAIN              Site domain (without --slug, a random slug is prepended to it)
#   --db-type postgres|mysql     DB type
#   --ssl-email EMAIL            Email for Let's Encrypt (not needed with --no-ssl)
#
# Project:
#   --slug SLUG                  Project identifier (random by default)
#   --laravel-version X.Y        Laravel version (minimum LARAVEL_MIN_VERSION in versions.env, 12.0; default 13.0)
#   --create-backup              Create a zip archive of the project in /tmp after deployment
#   --endpoint URL               Send project data (JSON, PUT) to URL
#
# Filament:
#   --install-filament           Install filament/filament and the /admin panel
#   --filament-email EMAIL       Admin email (required with --install-filament)
#   --filament-name NAME         Admin name (generated if not given)
#   --filament-password PASS     Admin password (generated if not given)
#
# Modules (optional features; see modules/README.md):
#   --with NAME[,NAME]           Enable modules, e.g. --with filament,redis,queue or --with horizon
#   --list-modules               List the available modules and exit
#   --backup-keep DAYS           Days to keep the database dumps of the backup module (default 7)
#   Aliases: --install-filament = --with filament, --use-redis = --with redis, --queue-worker = --with queue
#
# Existing application (instead of a fresh Laravel):
#   --repo URL                   Deploy an existing Laravel application from a git repository
#                                (https://, ssh:// or git@host:path; no credentials inside the URL)
#   --branch BRANCH              Branch to deploy (default: the repository's default branch)
#   --deploy-key PATH            SSH private key for a private repository (needs an SSH URL)
#   --post-deploy "COMMANDS"     Shell commands run in the php container after the deployment
#                                (also works without --repo); use update.sh --slug X to update later
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
#   --bind-local                 Compatibility flag: project ports are always loopback-only
#   --use-redis                  Wire Redis into Laravel (REDIS_*; cache, session and queue use redis)
#   --queue-worker               Run a queue worker container (php artisan queue:work)
#   --php-upload-max SIZE        PHP upload_max_filesize and post_max_size, e.g. 64M (default: PHP defaults 2M/8M)
#   -h, --help                   Show this help
#
# The script must be located next to the template folders laravel/ and nginxproxy/.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=lib/proxy.sh
source "$SCRIPT_DIR/lib/proxy.sh"
SCRIPT_VERSION="unknown"
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
    SCRIPT_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
fi
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
    # The help is the header comment: from the first "# ====" line to the first line that is not a comment
    awk '!started { if (/^# =+$/) started = 1; next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
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
    if [[ "$DRY_RUN" == true ]]; then echo "<generated>"; return; fi
    echo "$(random_string 'a-z' 1)$(random_string 'a-z0-9' 14)"
}

# generate_random_password - generates a strong password (15 characters)
# Without characters that break sed (&, |, /, \), .env and docker compose ($, #, =, quotes)
generate_random_password() {
    if [[ "$DRY_RUN" == true ]]; then echo "<generated>"; return; fi
    random_string 'A-Za-z0-9@%_+-' 15
}

# ==================== Versions (versions.env) ====================
# Built-in defaults; versions.env next to the script overrides them, so a version is bumped in one place.
DEFAULT_LARAVEL_VERSION="13.0"
MIN_LARAVEL_VERSION="12.0"
FILAMENT_VERSION="^5.0"
POSTGRES_IMAGE="postgres:17"
MYSQL_IMAGE="mysql:8.4"

# Trims whitespace around a value and strips one pair of matching quotes.
unquote() {
    local V="$1"
    V="${V#"${V%%[![:space:]]*}"}"
    V="${V%"${V##*[![:space:]]}"}"
    if [[ ${#V} -ge 2 && ( "$V" == \"*\" || "$V" == \'*\' ) ]]; then
        V="${V:1:${#V}-2}"
    fi
    printf '%s' "$V"
}

load_versions() {
    local FILE="${SCRIPT_DIR}/versions.env" LINE KEY VALUE CONSTRAINT_RE
    if [[ ! -f "$FILE" ]]; then
        return
    fi
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        LINE="${LINE%$'\r'}"
        [[ "$LINE" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$LINE" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]]; then
            error "Invalid line in versions.env: ${LINE}"
        fi
        KEY="${BASH_REMATCH[1]}"
        VALUE="$(unquote "${BASH_REMATCH[2]}")"
        case "$KEY" in
            LARAVEL_VERSION)
                [[ "$VALUE" =~ ^[0-9]+\.[0-9]+$ ]] || error "Invalid LARAVEL_VERSION in versions.env: ${VALUE} (expected X.Y, for example 13.0)"
                DEFAULT_LARAVEL_VERSION="$VALUE" ;;
            LARAVEL_MIN_VERSION)
                [[ "$VALUE" =~ ^[0-9]+\.[0-9]+$ ]] || error "Invalid LARAVEL_MIN_VERSION in versions.env: ${VALUE} (expected X.Y, for example 12.0)"
                MIN_LARAVEL_VERSION="$VALUE" ;;
            FILAMENT_VERSION)
                # A composer constraint: digits, letters, . ^ ~ * , < > = | space and -
                CONSTRAINT_RE='^[0-9A-Za-z.^~*,<>=| -]+$'
                [[ "$VALUE" =~ $CONSTRAINT_RE ]] || error "Invalid FILAMENT_VERSION in versions.env: ${VALUE} (expected a composer constraint such as ^5.0)"
                FILAMENT_VERSION="$VALUE" ;;
            POSTGRES_IMAGE|MYSQL_IMAGE)
                [[ "$VALUE" =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$ ]] || error "Invalid ${KEY} in versions.env: ${VALUE} (expected image:tag)"
                if [[ "$KEY" == "POSTGRES_IMAGE" ]]; then POSTGRES_IMAGE="$VALUE"; else MYSQL_IMAGE="$VALUE"; fi ;;
            *) error "Unknown key in versions.env: ${KEY}" ;;
        esac
    done < "$FILE"
}

# ==================== Configuration file (--config) ====================
# Every setting of the command line can live in a KEY=VALUE file. The key is the flag name in
# upper case with '_' for '-' (DB_TYPE = --db-type). Boolean flags take true/yes/1/on to enable
# and false/no/0/off (or an empty value) to leave the flag off. The file is parsed line by line and
# never sourced. Flags given on the command line override the file.
CONFIG_VALUE_FLAGS=(with backup-keep slug domain laravel-version filament-email filament-name filament-password port-http port-https port-php port-redis port-postgres port-mysql redis-password db-type db-mysql-name db-mysql-user db-mysql-password db-mysql-root-password db-postgres-name db-postgres-user db-postgres-password db-root-password auth-user auth-password ssl-email endpoint php-upload-max repo branch deploy-key post-deploy)
CONFIG_BOOL_FLAGS=(install-filament create-backup db-native create-dhparam enable-basic-auth no-ssl obtain-ssl bind-local use-redis queue-worker)
CONFIG_ARGS=()
DRY_RUN=false
USED_PRESETS=()
USED_CONFIG=""
PRESETS_DIR="${SCRIPT_DIR}/presets"

in_list() {
    local NEEDLE="$1" ITEM
    shift
    for ITEM in "$@"; do
        [[ "$ITEM" == "$NEEDLE" ]] && return 0
    done
    return 1
}

# read_config_file <file> [preset]: appends the flags described by the file to CONFIG_ARGS.
# The optional second argument marks a preset (shipped with the script): no permission warning, no PRESET=.
read_config_file() {
    local FILE="$1" MODE="${2:-config}" LINE KEY VALUE FLAG LOWER N=0
    if [[ ! -f "$FILE" || ! -r "$FILE" ]]; then
        error "Config file not found or not readable: ${FILE}"
    fi
    if [[ "$MODE" == config && "$(stat -c '%a' "$FILE")" != *0 ]]; then
        warn "Config file ${FILE} is accessible to other users and may hold passwords. Restrict it: chmod 600 ${FILE}"
    fi
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        N=$((N + 1))
        LINE="${LINE%$'\r'}"
        [[ "$LINE" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$LINE" =~ ^[[:space:]]*([A-Za-z][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            error "Invalid line ${N} in ${FILE}: expected KEY=VALUE"
        fi
        KEY="${BASH_REMATCH[1]}"
        VALUE="$(unquote "${BASH_REMATCH[2]}")"
        FLAG="$(printf '%s' "$KEY" | tr 'A-Z_' 'a-z-')"
        if [[ "$FLAG" == "preset" ]]; then
            [[ "$MODE" != preset ]] || error "A preset cannot include another preset (PRESET in ${FILE}, line ${N})"
            [[ -z "$VALUE" ]] || load_preset "$VALUE"
        elif in_list "$FLAG" "${CONFIG_BOOL_FLAGS[@]}"; then
            LOWER="$(printf '%s' "$VALUE" | tr 'A-Z' 'a-z')"
            case "$LOWER" in
                true|yes|1|on)       CONFIG_ARGS+=("--${FLAG}") ;;
                false|no|0|off|"")   ;;
                *) error "Invalid value for ${KEY} in ${FILE} (line ${N}): ${VALUE} (use true or false)" ;;
            esac
        elif in_list "$FLAG" "${CONFIG_VALUE_FLAGS[@]}"; then
            if [[ -n "$VALUE" ]]; then
                CONFIG_ARGS+=("--${FLAG}" "$VALUE")
            fi
        else
            error "Unknown key ${KEY} in ${FILE} (line ${N})"
        fi
    done < "$FILE"
}

# ==================== Presets (presets/*.conf) and --dry-run ====================
# A preset is a --config file shipped with the script. Settings are applied in this order, a later
# one overriding an earlier one: presets, the --config file, the command line. A preset can only add
# (modules accumulate, a boolean flag that is on cannot be switched off later).
load_preset() {
    local NAME="$1" FILE
    [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || error "Invalid preset name: ${NAME} (lowercase letters, digits and '-')"
    FILE="${PRESETS_DIR}/${NAME}.conf"
    [[ -f "$FILE" ]] || error "Unknown preset: ${NAME} (see --list-presets)"
    info "Using preset: ${NAME}"
    USED_PRESETS+=("$NAME")
    read_config_file "$FILE" preset
}

list_presets() {
    local FILE NAME DESC
    echo "Available presets (use with --preset NAME):"
    for FILE in "${PRESETS_DIR}"/*.conf; do
        [[ -f "$FILE" ]] || continue
        NAME="$(basename "$FILE" .conf)"
        [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || continue
        DESC="$(grep -m1 '^# Description:' "$FILE" | sed 's/^# Description: *//' || true)"
        printf '  %-12s %s\n' "$NAME" "${DESC:-(no description)}"
    done
}

join_by() {
    local SEP="$1" OUT="" ITEM
    shift
    for ITEM in "$@"; do
        OUT="${OUT:+${OUT}${SEP}}${ITEM}"
    done
    printf '%s' "$OUT"
}

# --dry-run: the settings after presets, the config file and the flags were applied. No secrets are printed.
print_dry_run() {
    local PRESETS_LIST="none" MODULES_LIST="none" SOURCE DBDESC SSLDESC PORTS UPLOADS AUTH BACKUP DUMPS ENDP POST
    if [[ ${#USED_PRESETS[@]} -gt 0 ]]; then PRESETS_LIST="$(join_by ', ' "${USED_PRESETS[@]}")"; fi
    if [[ ${#ENABLED_MODULES[@]} -gt 0 ]]; then MODULES_LIST="$(join_by ', ' "${ENABLED_MODULES[@]}")"; fi

    if [[ -n "$REPO_URL" ]]; then
        SOURCE="existing application ${REPO_URL} (${REPO_BRANCH:-default branch})"
    else
        SOURCE="fresh Laravel ^${LARAVEL_VERSION}"
    fi
    if [[ "$DB_NATIVE" == true ]]; then DBDESC="${DB_TYPE}, native on the host"; else DBDESC="${DB_TYPE}, in a container"; fi
    if [[ "$OBTAIN_SSL" == true ]]; then SSLDESC="Let's Encrypt (${SSL_EMAIL})"; else SSLDESC="not requested (--no-ssl)"; fi
    PORTS="published on 127.0.0.1 only (default)"
    if [[ -n "$PHP_UPLOAD_MAX" ]]; then UPLOADS="upload_max_filesize = post_max_size = ${PHP_UPLOAD_MAX}"; else UPLOADS="PHP defaults (2M/8M)"; fi
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then AUTH="on"; else AUTH="off"; fi
    if [[ "$CREATE_BACKUP" == true ]]; then BACKUP="zip in /tmp after the deployment"; else BACKUP="off"; fi
    if [[ -n "$ENDPOINT" ]]; then ENDP="set"; else ENDP="none"; fi
    if [[ -n "$POST_DEPLOY" ]]; then POST="set"; else POST="none"; fi

    echo "Effective settings (dry run: nothing was changed)"
    echo ""
    printf '  %-13s %s\n' "Presets:" "$PRESETS_LIST"
    printf '  %-13s %s\n' "Config file:" "${USED_CONFIG:-none}"
    printf '  %-13s %s\n' "Slug:" "$SLUG"
    printf '  %-13s %s\n' "Domain:" "$DOMAIN"
    printf '  %-13s %s\n' "Source:" "$SOURCE"
    printf '  %-13s %s\n' "Database:" "$DBDESC"
    printf '  %-13s %s\n' "Modules:" "$MODULES_LIST"
    printf '  %-13s %s\n' "Ports:" "$PORTS"
    printf '  %-13s %s\n' "PHP uploads:" "$UPLOADS"
    printf '  %-13s %s\n' "Basic Auth:" "$AUTH"
    printf '  %-13s %s\n' "SSL:" "$SSLDESC"
    printf '  %-13s %s\n' "Backup:" "$BACKUP"
    if module_enabled backup; then DUMPS="daily, kept ${BACKUP_KEEP_DAYS} days (module backup)"; else DUMPS="off"; fi
    printf '  %-13s %s\n' "DB dumps:" "$DUMPS"
    printf '  %-13s %s\n' "Endpoint:" "$ENDP"
    printf '  %-13s %s\n' "Post-deploy:" "$POST"
    echo ""
    echo "Nothing was changed. Run the same command without --dry-run, as root, to deploy."
}

# ==================== Modules (modules/*.sh) ====================
# A module is an optional feature: modules/<name>.sh next to the script. It is loaded (sourced, so it
# runs as root in this shell, like the script itself) only when enabled with --with NAME[,NAME] or
# one of the aliases (--install-filament, --use-redis, --queue-worker). See modules/README.md.
#
# A module defines MOD_<NAME>_DESCRIPTION, optionally MOD_<NAME>_REQUIRES (modules it needs; they
# are enabled automatically) and any of the hooks mod_<name>_validate, _env, _install, _compose and
# _summary (in the name, '-' becomes '_').
MODULES_DIR="${SCRIPT_DIR}/modules"
ENABLED_MODULES=()
MODULES_SEEN=()

module_ident() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
module_fn()    { printf 'mod_%s_%s' "$(printf '%s' "$1" | tr '-' '_')" "$2"; }
module_exists() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ && -f "${MODULES_DIR}/$1.sh" ]]; }
module_enabled() { in_list "$1" ${ENABLED_MODULES[@]+"${ENABLED_MODULES[@]}"}; }

# enable_module <name>: loads the module and, first, the modules it requires
enable_module() {
    local NAME="$1" REQ VAR
    if in_list "$NAME" ${MODULES_SEEN[@]+"${MODULES_SEEN[@]}"}; then
        return
    fi
    MODULES_SEEN+=("$NAME")
    module_exists "$NAME" || error "Unknown module: ${NAME} (see --list-modules)"
    # shellcheck source=/dev/null
    source "${MODULES_DIR}/${NAME}.sh"
    VAR="MOD_$(module_ident "$NAME")_REQUIRES"
    for REQ in ${!VAR:-}; do
        if ! in_list "$REQ" ${MODULES_SEEN[@]+"${MODULES_SEEN[@]}"}; then
            info "Module ${NAME} requires ${REQ}: enabling it"
        fi
        enable_module "$REQ"
    done
    ENABLED_MODULES+=("$NAME")
}

# parse_module_list "a,b": the value of --with
parse_module_list() {
    local NAME
    local -a NAMES
    IFS=',' read -r -a NAMES <<< "$1"
    for NAME in ${NAMES[@]+"${NAMES[@]}"}; do
        NAME="$(unquote "$NAME")"
        [[ -n "$NAME" ]] || continue
        [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || error "Invalid module name: ${NAME} (lowercase letters, digits and '-')"
        enable_module "$NAME"
    done
}

# run_module_hook <hook> [args]: calls mod_<name>_<hook> of every enabled module that defines it
run_module_hook() {
    local HOOK="$1" NAME FN
    shift
    for NAME in ${ENABLED_MODULES[@]+"${ENABLED_MODULES[@]}"}; do
        FN="$(module_fn "$NAME" "$HOOK")"
        if declare -F "$FN" > /dev/null; then
            "$FN" "$@" || error "Module $NAME failed at hook $HOOK"
        fi
    done
}

list_modules() {
    local FILE NAME DVAR RVAR
    echo "Available modules (enable with --with NAME[,NAME]):"
    for FILE in "${MODULES_DIR}"/*.sh; do
        [[ -f "$FILE" ]] || continue
        NAME="$(basename "$FILE" .sh)"
        [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || continue
        (
            # shellcheck source=/dev/null
            source "$FILE"
            DVAR="MOD_$(module_ident "$NAME")_DESCRIPTION"
            RVAR="MOD_$(module_ident "$NAME")_REQUIRES"
            printf '  %-10s %s\n' "$NAME" "${!DVAR:-(no description)}"
            if [[ -n "${!RVAR:-}" ]]; then
                printf '  %-10s   requires: %s\n' "" "${!RVAR}"
            fi
        )
    done
}

# add_compose_service <yaml>: inserts service definitions (2-space indented, {SLUG} is replaced)
# into the project's docker-compose.yml, before the top-level "networks:" section
add_compose_service() {
    local FILE="${PROJECT_DIR}/docker-compose.yml" SNIPFILE TMP
    grep -q '^networks:' "$FILE" || error "docker-compose.yml has no top-level networks: section; cannot add a module service"
    SNIPFILE="$(mktemp)"
    TMP="$(mktemp)"
    printf '%s\n' "$1" | sed "s/{SLUG}/${SLUG}/g" > "$SNIPFILE"
    awk -v f="$SNIPFILE" '!done && /^networks:/ { while ((getline l < f) > 0) print l; close(f); done = 1 } { print }' "$FILE" > "$TMP"
    if ! docker compose --project-directory "$PROJECT_DIR" -f "$TMP" config -q; then
        rm -f "$SNIPFILE" "$TMP"
        error "Invalid module Compose configuration; project configuration unchanged"
    fi
    cat "$TMP" > "$FILE" || error "Cannot save module Compose configuration"
    rm -f "$SNIPFILE" "$TMP"
}

# generate_random_slug - generates a random slug (8 characters)
generate_random_slug() {
    random_string 'a-z0-9' 8
}

# Escapes a string for the right-hand side of a sed substitution (s|...|HERE|)
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# docker_bridge_ip: the address of the Docker host as a container sees it, i.e. the gateway of Docker's
# default "bridge" network. It is 172.17.0.1 unless the daemon's "bip" option was changed; the script
# uses it as DB_HOST for a database installed on the host (--db-native).
docker_bridge_ip() {
    local IP
    IP="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || IP="172.17.0.1"
    printf '%s' "$IP"
}

# explain_composer_failure <log>: Composer (2.9+) refuses package versions that are affected by security
# advisories ("audit.block-insecure"). Laravel releases that are no longer supported keep unfixed advisories,
# so installing them fails with a message that does not say why. Explain it.
explain_composer_failure() {
    local LOG="$1"
    if grep -q "security advisories" "$LOG" 2>/dev/null; then
        warn "Composer refused to install the requested versions because they are affected by security advisories."
        warn "That is Composer's security blocking (audit.block-insecure), not a fault of this script. Laravel versions"
        warn "that are no longer supported, such as 10.x and 11.x, keep unfixed advisories and cannot be installed."
        warn "Use a supported Laravel version: the default is ${DEFAULT_LARAVEL_VERSION} (versions.env). For an existing application"
        warn "(--repo), upgrade its framework, or commit a composer.lock that Composer accepts."
    fi
}

# Sets KEY=VALUE in an .env file: replaces an existing (possibly commented-out) line, otherwise appends it
set_env_var() {
    local FILE="$1" KEY="$2" VALUE="$3"
    if grep -qE "^#? *${KEY}=" "$FILE"; then
        local ESCAPED
        ESCAPED=$(sed_escape "$VALUE") || error "Cannot encode environment value for $KEY"
        sed -i "s|^#\? *${KEY}=.*|${KEY}=${ESCAPED}|" "$FILE" || error "Cannot update $KEY in $FILE"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$FILE" || error "Cannot append $KEY to $FILE"
    fi
}

# Quote DB values without expanding $variables. Laravel env() also converts reserved strings.
db_env_value() {
    local VALUE="$1" FORMAT="${2:-compose}"
    if [[ "$FORMAT" == laravel ]]; then
        case "${VALUE,,}" in
            true|false|null|empty|'(true)'|'(false)'|'(null)'|'(empty)') VALUE="\"$VALUE\"" ;;
            *)
                if [[ ( "$VALUE" == \"*\" || "$VALUE" == \'*\' ) && ${#VALUE} -ge 2 ]]; then
                    VALUE="\"$VALUE\""
                fi
                ;;
        esac
    fi
    if [[ "$VALUE" =~ ^[A-Za-z0-9@%_+-]+$ ]]; then
        printf '%s' "$VALUE"
        return
    fi
    VALUE=${VALUE//\\/\\\\}
    VALUE=${VALUE//\"/\\\"}
    VALUE=${VALUE//\$/\\\$}
    printf '"%s"' "$VALUE"
}

# Names are also copied into Compose/YAML and management metadata, so keep a portable alphabet.
validate_database_credentials() {
    local LC_ALL=C DB_NAME_VALUE DB_USER_VALUE DB_PASSWORD_VALUE ROOT_PASSWORD_VALUE="" NAME_MAX=63 USER_MAX=63
    if [[ "$DB_TYPE" == postgres ]]; then
        DB_NAME_VALUE="$DB_POSTGRES_NAME"; DB_USER_VALUE="$DB_POSTGRES_USER"; DB_PASSWORD_VALUE="$DB_POSTGRES_PASSWORD"
    else
        DB_NAME_VALUE="$DB_MYSQL_NAME"; DB_USER_VALUE="$DB_MYSQL_USER"; DB_PASSWORD_VALUE="$DB_MYSQL_PASSWORD"
        ROOT_PASSWORD_VALUE="$DB_MYSQL_ROOT_PASSWORD"
        NAME_MAX=64; USER_MAX=32
    fi
    [[ ( "$DRY_RUN" == true && "$DB_NAME_VALUE" == '<generated>' ) ||
        ( "$DB_NAME_VALUE" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ && ${#DB_NAME_VALUE} -le $NAME_MAX ) ]] ||
        error "Invalid database name: use 1-${NAME_MAX} ASCII letters, digits, underscores or hyphens"
    [[ ( "$DRY_RUN" == true && "$DB_USER_VALUE" == '<generated>' ) ||
        ( "$DB_USER_VALUE" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ && ${#DB_USER_VALUE} -le $USER_MAX ) ]] ||
        error "Invalid database user: use 1-${USER_MAX} ASCII letters, digits, underscores or hyphens"
    [[ "$DB_PASSWORD_VALUE$ROOT_PASSWORD_VALUE$DB_ROOT_PASSWORD" != *[[:cntrl:]]* ]] ||
        error "Database passwords must not contain control characters"
    if [[ "$DB_TYPE" == mysql && "$DB_NATIVE" != true && "$DB_USER_VALUE" == root ]]; then
        error "Containerized MySQL requires a separate application user; --db-mysql-user cannot be root"
    fi
    # The official MySQL entrypoint inserts these secrets into SQL and client config.
    # Refuse unsupported input before Docker instead of passing an injection to that initializer.
    if [[ "$DB_TYPE" == mysql && "$DB_NATIVE" != true &&
        "$DB_PASSWORD_VALUE$ROOT_PASSWORD_VALUE" == *[\'\"\\]* ]]; then
        error "Containerized MySQL passwords cannot contain quotes or backslashes; native MySQL supports these characters"
    fi
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
    local LISTENERS
    LISTENERS=$(ss -H -ltn) || error "Cannot inspect listening TCP ports"

    while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
        local PORT=$(( RANDOM % RANGE + MIN ))
        if ! awk -v port="$PORT" '$4 ~ (":" port "$") { found=1 } END { exit !found }' <<< "$LISTENERS"; then
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
    mkdir -p "${PROXY_DIR}/sites" || error "Cannot create proxy candidate"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.Dockerfile"   "${PROXY_DIR}/nginx.Dockerfile" || error "Cannot copy proxy Dockerfile"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.conf"         "${PROXY_DIR}/nginx.conf" || error "Cannot copy proxy configuration"
    cp "${SCRIPT_DIR}/nginxproxy/site-template.conf" "${PROXY_DIR}/site-template.conf" || error "Cannot copy proxy template"

    # Base proxy docker-compose.yml — without networks/volumes, they are added per site
    cat > "${PROXY_DIR}/docker-compose.yml" <<'DCEOF' || error "Cannot create proxy Compose configuration"
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
    local DHPARAM_FILE="${PROJECT_DIR}/.config/nginx/dhparam.pem"

    if [[ "$CREATE_DHPARAM" != true ]]; then
        return
    fi

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "File dhparam.pem already exists: ${DHPARAM_FILE}"
        return
    fi

    info "Creating dhparam.pem (this takes a few minutes)..."
    docker run --rm -v "${PROJECT_DIR}/.config/nginx:/output" alpine/openssl dhparam -out /output/dhparam.pem 2048 || error "Failed to create dhparam.pem"

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "dhparam.pem created successfully: ${DHPARAM_FILE}"
    else
        error "Failed to create dhparam.pem"
    fi
}

# ==================== Argument parsing ====================
SLUG=""
DOMAIN=""
LARAVEL_VERSION=""
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
FILAMENT_EMAIL=""
FILAMENT_NAME=""
FILAMENT_PASSWORD=""
CREATE_BACKUP=false
BACKUP_FILE_PATH=""
REPO_URL=""
REPO_BRANCH=""
DEPLOY_KEY=""
POST_DEPLOY=""
POST_DEPLOY_FAILED=false
LARAVEL_VERSION_SET=false
BIND_LOCAL=true
PHP_UPLOAD_MAX=""
BACKUP_KEEP_DAYS=7

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)                   SLUG="$2";                   shift 2 ;;
            --domain)                 DOMAIN="$2";                 shift 2 ;;
            --type)
                # Compatibility with calls from the old deploy.sh
                [[ "$2" == "$APP_TYPE" ]] || error "This script only deploys Laravel. For '$2' use deploy-$2.sh"
                shift 2 ;;
            --laravel-version)        LARAVEL_VERSION="$2"; LARAVEL_VERSION_SET=true; shift 2 ;;
            --install-filament)       enable_module filament;      shift 1 ;;
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
            --repo)                   REPO_URL="$2";               shift 2 ;;
            --branch)                 REPO_BRANCH="$2";            shift 2 ;;
            --deploy-key)             DEPLOY_KEY="$2";             shift 2 ;;
            --post-deploy)            POST_DEPLOY="$2";            shift 2 ;;
            --bind-local)             BIND_LOCAL=true;             shift 1 ;;
            --use-redis)              enable_module redis;         shift 1 ;;
            --queue-worker)           enable_module queue;         shift 1 ;;
            --with)                   parse_module_list "$2";      shift 2 ;;
            --backup-keep)            BACKUP_KEEP_DAYS="$2";       shift 2 ;;
            --php-upload-max)         PHP_UPLOAD_MAX="$2";         shift 2 ;;
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
    if [[ "${SLUG,,}" == nginxproxy ]]; then
        error "The slug nginxproxy is reserved for the shared reverse proxy"
    fi
    if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Invalid domain: ${DOMAIN}"
    fi
    if [[ -n "$REPO_URL" ]]; then
        # Credentials inside the URL would end up in .git/config, `ps` and logs
        if [[ "$REPO_URL" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/@]*:[^/@]*@ || "$REPO_URL" =~ ^https?://[^/@]*@ ]]; then
            error "The --repo URL must not contain credentials. For a private repository use an SSH URL with --deploy-key"
        fi
        if ! [[ "$REPO_URL" =~ ^(https?://|ssh://|git://|file://|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:) ]]; then
            error "Unsupported --repo URL: ${REPO_URL} (expected https://, ssh://, git@host:path or file://)"
        fi
        if [[ -n "$REPO_BRANCH" ]] && ! [[ "$REPO_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
            error "Invalid --branch: ${REPO_BRANCH}"
        fi
        if [[ "$LARAVEL_VERSION_SET" == true ]]; then
            error "--laravel-version cannot be combined with --repo: the version comes from the repository"
        fi
        if [[ -n "$DEPLOY_KEY" ]]; then
            [[ -f "$DEPLOY_KEY" ]] || error "Deploy key not found: ${DEPLOY_KEY}"
            if ! [[ "$REPO_URL" =~ ^(ssh://|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:) ]]; then
                error "--deploy-key requires an SSH repository URL (git@host:owner/repo.git or ssh://...)"
            fi
        fi
    else
        [[ -z "$REPO_BRANCH" ]] || error "--branch requires --repo"
        [[ -z "$DEPLOY_KEY" ]] || error "--deploy-key requires --repo"
    fi
    if [[ "$POST_DEPLOY" == *$'\n'* ]]; then
        error "--post-deploy must be a single line (join commands with && or ;)"
    fi
    if [[ -n "$PHP_UPLOAD_MAX" ]] && ! [[ "$PHP_UPLOAD_MAX" =~ ^[0-9]+[KMGkmg]?$ ]]; then
        error "Invalid --php-upload-max value: ${PHP_UPLOAD_MAX} (expected a size such as 64M, 512M or 1G)"
    fi

    # --- Validate Laravel version ---
    if ! [[ "$LARAVEL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        error "Invalid Laravel version format: ${LARAVEL_VERSION}. Expected X.Y (for example: 12.0)"
    fi
    # sort -V puts the smaller X.Y first: below the minimum if the minimum is not the smallest of the two
    if [[ "$(printf '%s\n%s\n' "$MIN_LARAVEL_VERSION" "$LARAVEL_VERSION" | sort -V | head -n1)" != "$MIN_LARAVEL_VERSION" ]]; then
        error "Minimum supported Laravel version: ${MIN_LARAVEL_VERSION}, got: ${LARAVEL_VERSION}. Older releases (10.x, 11.x) are no longer supported, and Composer refuses them because of unfixed security advisories."
    fi
    if [[ -n "$REPO_URL" ]]; then
        info "Application source: ${REPO_URL}"
    else
        info "Laravel version to be installed: ^${LARAVEL_VERSION}"
    fi

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

    validate_database_credentials
    [[ "$REDIS_PASSWORD$AUTH_PASSWORD$FILAMENT_PASSWORD" != *[[:cntrl:]]* ]] || error "Service passwords must not contain control characters"
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        [[ ( "$DRY_RUN" == true && "$AUTH_USER" == '<generated>' ) || "$AUTH_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] || error "Invalid Basic Auth username"
    fi
    validate_port_values

    # --- Modules validate their own options (for example Filament needs --filament-email) ---
    run_module_hook validate

    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        error "Template directory not found: ${TEMPLATE_DIR}"
    fi
}

# ==================== Port assignment ====================
validate_port_values() {
    local VAR VALUE OTHER ACTIVE=(PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS)
    if [[ "$DB_NATIVE" != true ]]; then
        if [[ "$DB_TYPE" == postgres ]]; then ACTIVE+=(PORT_POSTGRES); else ACTIVE+=(PORT_MYSQL); fi
    fi
    for VAR in PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS PORT_POSTGRES PORT_MYSQL; do
        VALUE="${!VAR}"
        [[ -z "$VALUE" ]] && continue
        [[ "$VALUE" =~ ^[0-9]{1,5}$ ]] && (( 10#$VALUE >= 1 && 10#$VALUE <= 65535 )) ||
            error "Invalid port $VAR: $VALUE (expected 1-65535)"
        printf -v "$VAR" '%d' "$((10#$VALUE))"
    done
    local SEEN=""
    for VAR in "${ACTIVE[@]}"; do
        VALUE="${!VAR}"
        [[ -z "$VALUE" ]] && continue
        [[ "$VALUE" != 80 && "$VALUE" != 443 ]] || error "Project port $VALUE is reserved for the shared proxy"
        for OTHER in $SEEN; do
            [[ "$OTHER" != "$VALUE" ]] || error "Duplicate project port: $VALUE"
        done
        SEEN="$SEEN $VALUE"
    done
}

check_port_availability() {
    local VAR VALUE LISTENERS ACTIVE=(PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS)
    if [[ "$DB_NATIVE" != true ]]; then
        if [[ "$DB_TYPE" == postgres ]]; then ACTIVE+=(PORT_POSTGRES); else ACTIVE+=(PORT_MYSQL); fi
    fi
    LISTENERS=$(ss -H -ltn) || error "Cannot inspect listening TCP ports"
    for VAR in "${ACTIVE[@]}"; do
        VALUE="${!VAR}"
        if awk '{print $4}' <<< "$LISTENERS" | grep -qE ":${VALUE}$"; then
            error "Port $VALUE ($VAR) is already in use"
        fi
    done
}

# Manually specified ports are left unchanged; the rest are picked from the ranges
assign_ports() {
    info "Selecting free ports..."
    runtime_require ss python3 flock

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

    python3 - "$COMPOSE_FILE" "$SLUG" "$DB_TYPE" "$DB_NATIVE" <<'PYEOF' || error "Failed to edit configuration"
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
    (
    umask 077
    {
        echo "SITE_HOST=${DOMAIN}"
        echo "SITE_PORT_HTTP=${PORT_HTTP}"
        echo "SITE_PORT_HTTPS=${PORT_HTTPS}"
        echo ""
        echo "PHP_PORT=${PORT_PHP}"
        echo ""
        echo "REDIS_PORT=${PORT_REDIS}"
        printf 'REDIS_PASSWORD=%s\n' "$(db_env_value "$REDIS_PASSWORD")"
        echo ""
        if [[ "$DB_TYPE" == "postgres" ]]; then
            echo "DB_PORT=${PORT_POSTGRES}"
            echo "DB_POSTGRES_NAME=${DB_POSTGRES_NAME}"
            echo "DB_POSTGRES_USER=${DB_POSTGRES_USER}"
            printf 'DB_POSTGRES_PASSWORD=%s\n' "$(db_env_value "$DB_POSTGRES_PASSWORD")"
        else
            echo "DB_PORT=${PORT_MYSQL}"
            echo "DB_MYSQL_NAME=${DB_MYSQL_NAME}"
            echo "DB_MYSQL_USER=${DB_MYSQL_USER}"
            printf 'DB_MYSQL_PASSWORD=%s\n' "$(db_env_value "$DB_MYSQL_PASSWORD")"
            printf 'DB_MYSQL_PASSWORD_ROOT=%s\n' "$(db_env_value "$DB_MYSQL_ROOT_PASSWORD")"
        fi
        echo ""
        echo "DB_NATIVE=${DB_NATIVE}"
        if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
            echo ""
            printf 'AUTH_USER=%s\n' "$(db_env_value "$AUTH_USER")"
            printf 'AUTH_PASSWORD=%s\n' "$(db_env_value "$AUTH_PASSWORD")"
        fi
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    )
}

# Refuse before touching Docker or the shared proxy; repeat the check at creation time.
check_project_target() {
    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    if [[ "${SLUG,,}" == nginxproxy ]]; then
        error "The slug nginxproxy is reserved for the shared reverse proxy"
    fi
    if [[ -e "$PROJECT_DIR" || -L "$PROJECT_DIR" ]]; then
        error "Project path already exists: ${PROJECT_DIR}. Nothing was replaced. Use update.sh for an application deployed with --repo, or explicitly remove the project before reinstalling."
    fi
}

# ==================== Project creation ======================
create_project() {
    check_project_target

    info "Creating project ${SLUG} (${APP_TYPE}) in ${PROJECT_DIR}..."
    mkdir "${PROJECT_DIR}" || error "Cannot create ${PROJECT_DIR}; nothing was replaced"

    # Copy the entire template contents
    cp -a "${TEMPLATE_DIR}/." "${PROJECT_DIR}/"

    # --- Organize Dockerfiles into subfolders ---
    if [[ -d "${PROJECT_DIR}/.docker" ]]; then
        mkdir -p "${PROJECT_DIR}/.docker/php"
        mkdir -p "${PROJECT_DIR}/.docker/nginx"

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

    # --- Database images from versions.env ---
    sed -i -e "s|image: postgres:17|image: ${POSTGRES_IMAGE}|" -e "s|image: mysql:8.4|image: ${MYSQL_IMAGE}|" "${PROJECT_DIR}/docker-compose.yml"

    # --- --bind-local: publish the project's own ports on the loopback interface only ---
    # The shared nginxproxy reaches the project nginx over the Docker network, so nothing
    # needs these ports from outside. PHP-FPM is always bound to 127.0.0.1 in the template.
    if [[ "$BIND_LOCAL" == true ]]; then
        info "Binding HTTP/HTTPS, Redis and DB ports to 127.0.0.1 (--bind-local)..."
        # Quoted mappings ("${SITE_PORT_HTTP}:80", ...) and the unquoted MySQL one (- ${DB_PORT}:3306)
        sed -i -e 's#"\${\(SITE_PORT_HTTP\|SITE_PORT_HTTPS\|REDIS_PORT\|DB_PORT\)}:#"127.0.0.1:${\1}:#' \
               -e 's#^\(\s*- \)\${DB_PORT}:\([0-9]*\)\s*$#\1"127.0.0.1:${DB_PORT}:\2"#' \
               "${PROJECT_DIR}/docker-compose.yml"
    fi

    # --- --php-upload-max: PHP upload limits via the mounted project.ini ---
    if [[ -n "$PHP_UPLOAD_MAX" ]]; then
        info "Setting PHP upload_max_filesize and post_max_size to ${PHP_UPLOAD_MAX}..."
        mkdir -p "${PROJECT_DIR}/.config/php"
        {
            echo "; Project-specific PHP settings, written by deploy-laravel.sh --php-upload-max."
            echo "; Mounted into the php container as conf.d/zz-project.ini. After editing: docker compose restart php"
            echo "upload_max_filesize = ${PHP_UPLOAD_MAX}"
            echo "post_max_size = ${PHP_UPLOAD_MAX}"
        } > "${PROJECT_DIR}/.config/php/project.ini"
    fi

    # --- Project .env ---
    write_project_env

    # --- Replace MYSITE.COM → domain in _site.conf ---
    if [[ -f "${PROJECT_DIR}/.config/nginx/_site.conf" ]]; then
        sed -i "s/MYSITE\.COM/${DOMAIN}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
        sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
        sed -i -e "s/MYSITE\\.COM/${DOMAIN}/g" -e "s/{SLUG}/${SLUG}/g" "$PROJECT_DIR/.config/nginx/_app.conf"
    fi

    # --- Uncomment dhparam.pem in docker-compose.yml and _site.conf ---
    if [[ "$CREATE_DHPARAM" == true ]]; then
        info "Uncommenting the dhparam.pem line in docker-compose.yml..."
        # The project is in /var/www/<slug>, the proxy in /var/www/nginxproxy, i.e. the path is ../nginxproxy
        sed -i 's|^\s*#\s*-.*dhparam\.pem:/etc/ssl/certs/dhparam\.pem.*|      - ./.config/nginx/dhparam.pem:/etc/ssl/certs/dhparam.pem:ro|' "${PROJECT_DIR}/docker-compose.yml"

        info "Uncommenting the ssl_dhparam line in _site.conf..."
        sed -i 's|^\s*#ssl_dhparam /etc/ssl/certs/dhparam\.pem;|        ssl_dhparam /etc/ssl/certs/dhparam.pem;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Create .htpasswd for Basic Auth ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        info "Creating .htpasswd file for Basic Authentication..."
        mkdir -p "${PROJECT_DIR}/.config/nginx"
        (umask 077; printf "%s\n" "$AUTH_PASSWORD" | docker run --rm -i httpd:alpine htpasswd -niB "$AUTH_USER" > "$PROJECT_DIR/.config/nginx/.htpasswd") || error "Cannot generate Basic Auth credentials"

        chown 101:101 "$PROJECT_DIR/.config/nginx/.htpasswd" || error "Cannot set Nginx credential ownership"
        if [[ -s "${PROJECT_DIR}/.config/nginx/.htpasswd" ]]; then
            info ".htpasswd file created: ${PROJECT_DIR}/.config/nginx/.htpasswd"

            info "Uncommenting the .htpasswd line in docker-compose.yml..."
            sed -i 's|^\s*#\s*-\s*\./.config/nginx/\.htpasswd:/etc/nginx/\.htpasswd:ro|      - ./.config/nginx/.htpasswd:/etc/nginx/.htpasswd:ro|' "${PROJECT_DIR}/docker-compose.yml"

            info "Uncommenting the Basic Auth lines in _site.conf..."
            sed -i 's|^#\s*auth_basic "Restricted Access";|            auth_basic "Restricted Access";|' "${PROJECT_DIR}/.config/nginx/_app.conf"
            sed -i 's|^#\s*auth_basic_user_file /etc/nginx/\.htpasswd;|            auth_basic_user_file /etc/nginx/.htpasswd;|' "${PROJECT_DIR}/.config/nginx/_app.conf"
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
        sed -i '/- \.\/nginx\.conf:\/etc\/nginx\/nginx\.conf:ro/a\      - ./sites:/etc/nginx/sites:ro' "${PROXY_DIR}/docker-compose.yml" || error "Cannot add proxy sites mount"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        warn "Config ${SITE_CONF} already exists, skipping."
        return
    fi

    info "Creating config ${SLUG}.conf from the template..."
    sed -e "s/SLUG/${SLUG}/g" \
        -e "s/DOMAIN/${DOMAIN}/g" \
        "$TEMPLATE" > "$SITE_CONF" || error "Failed to create proxy site configuration"

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

    python3 - "$DC" "$SLUG" <<'PYEOF' || error "Failed to edit configuration"
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
    local MODE="$1" SCOPE="${2:-project}"
    local FILES=()
    local FILE

    local TARGET
    if [[ "$SCOPE" == proxy ]]; then TARGET="$PROXY_DIR/sites/$SLUG.conf"
    else TARGET="$PROJECT_DIR/.config/nginx/_site.conf"; fi
    [[ ! -f "$TARGET" ]] || FILES+=("$TARGET")
    [[ ${#FILES[@]} -eq 0 ]] && return 0

    python3 - "$MODE" "${FILES[@]}" <<'PYEOF' || error "Failed to edit configuration"
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
            # Inspect this server's balanced block, not a fixed look-ahead that
            # can accidentally reach the next server when the HTTP block is short.
            window = []
            depth = 0
            for candidate in lines[idx:]:
                plain = candidate[1:] if mode == 'uncomment' and candidate.startswith('#') else candidate
                window.append(candidate)
                depth += plain.count('{') - plain.count('}')
                if depth == 0:
                    break
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
    validate_database_credentials

    info "Creating native ${DB_TYPE} database..."

    if [[ "$DB_TYPE" == "postgres" ]]; then
        if ! command -v psql &> /dev/null; then
            error "PostgreSQL is not installed on the server. Install PostgreSQL or use a containerized DB (remove the --db-native flag)"
        fi

        if ! sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "SELECT 1;" &> /dev/null; then
            error "PostgreSQL server is not running or unavailable. Start PostgreSQL: sudo systemctl start postgresql"
        fi

        info "Creating PostgreSQL user ${DB_POSTGRES_USER} and database ${DB_POSTGRES_NAME}"
        # psql quotes literals/identifiers itself; use stdin because -c does not interpolate variables.
        if ! sudo -u postgres psql -X -v ON_ERROR_STOP=1 \
            -v db_user="$DB_POSTGRES_USER" -v db_name="$DB_POSTGRES_NAME" \
        <<SQL
SET standard_conforming_strings = on;
SELECT '${DB_POSTGRES_PASSWORD//\'/\'\'}' AS db_password \gset
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user') AS user_exists \gset
\if :user_exists
\echo User :db_user already exists; password left unchanged
\else
CREATE USER :"db_user" WITH PASSWORD :'db_password';
\endif
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') AS database_exists \gset
\if :database_exists
\echo Database :db_name already exists
\else
CREATE DATABASE :"db_name" OWNER :"db_user";
\endif
GRANT ALL PRIVILEGES ON DATABASE :"db_name" TO :"db_user";
SQL
        then
            error "Failed to create native PostgreSQL user or database"
        fi

        success "PostgreSQL database ${DB_POSTGRES_NAME} created"

    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if ! command -v mysql &> /dev/null; then
            error "MySQL is not installed on the server. Install MySQL or use a containerized DB (remove the --db-native flag)"
        fi

        if ! mysql_private mysql -u root -e "SELECT 1;" <<< "$DB_ROOT_PASSWORD" &> /dev/null; then
            error "MySQL server is unavailable or the root password is wrong. Check: 1) MySQL is running (sudo systemctl start mysql), 2) --db-root-password is correct"
        fi

        local SQL_PASSWORD
        SQL_PASSWORD=${DB_MYSQL_PASSWORD//\'/\'\'}
        info "Creating MySQL user ${DB_MYSQL_USER} and database ${DB_MYSQL_NAME}"
        # Disable backslash escapes only in this session and double literal quotes.
        # --binary-mode also prevents mysql client commands embedded in input.
        # The '%' account admits application containers over the Docker bridge.
        if ! mysql_private mysql --binary-mode --default-character-set=utf8mb4 -u root <<SQL
${DB_ROOT_PASSWORD}
SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';
CREATE DATABASE IF NOT EXISTS \`${DB_MYSQL_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_MYSQL_USER}'@'%' IDENTIFIED BY '${SQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_MYSQL_NAME}\`.* TO '${DB_MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
SQL
        then
            error "Failed to create native MySQL user or database"
        fi

        success "MySQL database ${DB_MYSQL_NAME} created"
    fi
}

# ==================== Docker build and start ==============
wait_for_database() {
    local HOST PORT NAME USERNAME PASSWORD DEADLINE
    if [[ "$DB_TYPE" == postgres ]]; then
        PORT=5432; NAME="$DB_POSTGRES_NAME"; USERNAME="$DB_POSTGRES_USER"; PASSWORD="$DB_POSTGRES_PASSWORD"
        [[ "$DB_NATIVE" != true ]] || PORT="$PORT_POSTGRES"
    else
        PORT=3306; NAME="$DB_MYSQL_NAME"; USERNAME="$DB_MYSQL_USER"; PASSWORD="$DB_MYSQL_PASSWORD"
        [[ "$DB_NATIVE" != true ]] || PORT="$PORT_MYSQL"
    fi
    HOST="${SLUG}_db"
    [[ "$DB_NATIVE" != true ]] || HOST=$(docker_bridge_ip)
    info "Waiting for an authenticated database connection (up to 120 seconds)..."
    DEADLINE=$((SECONDS + 120))
    while (( SECONDS < DEADLINE )); do
        if printf '%s\0' "$DB_TYPE" "$HOST" "$PORT" "$NAME" "$USERNAME" "$PASSWORD" |
            timeout 10 docker compose run --rm --name "${SLUG}_db_probe" --no-deps -T --entrypoint php php -r '
                $v = explode("\0", stream_get_contents(STDIN));
                $driver = $v[0] === "postgres" ? "pgsql" : "mysql";
                try {
                    new PDO("$driver:host=$v[1];port=$v[2];dbname=$v[3]" . ($driver === "pgsql" ? ";connect_timeout=2" : ""), $v[4], $v[5],
                        [PDO::ATTR_TIMEOUT => 2, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                } catch (Throwable $e) { exit(1); }
            ' >/dev/null 2>&1; then
            success "Database accepts the application credentials"
            return
        fi
        docker rm -f "${SLUG}_db_probe" >/dev/null 2>&1 || true
        sleep 2
    done
    error "Database did not accept the application credentials; check the database logs and connectivity"
}

check_project_http() {
    local ATTEMPT CODE CREDENTIALS="$AUTH_USER:$AUTH_PASSWORD"
    CREDENTIALS=${CREDENTIALS//\\/\\\\}
    CREDENTIALS=${CREDENTIALS//\"/\\\"}
    info "Checking the project's HTTP response..."
    for ATTEMPT in {1..10}; do
        CODE=$({
            if [[ "$ENABLE_BASIC_AUTH" == true ]]; then printf 'user = "%s"\n' "$CREDENTIALS"; fi
        } | curl --config - --connect-timeout 2 --max-time 5 -sS -o /dev/null -w '%{http_code}' \
            -H "Host: $DOMAIN" "http://127.0.0.1:$PORT_HTTP/" 2>/dev/null) || CODE=000
        # API applications may deliberately have no root route.
        if [[ "$CODE" =~ ^[23][0-9][0-9]$ || "$CODE" == 404 ]]; then
            success "Project HTTP responds successfully ($CODE)"
            return 0
        fi
        sleep 1
    done
    error "Project HTTP did not become ready (HTTP $CODE); project data retained. Check the PHP and Nginx logs."
}

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
    validate_port_values
    check_port_availability
    if ! docker compose up -d --build; then
        error "Failed to build/start the project. Check the logs: cd ${PROJECT_DIR} && docker compose logs"
    fi

    info "docker compose command completed successfully"

    # Give the containers time to start
    info "Waiting for containers to start..."
    wait_for_database

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

    local COMPOSER_LOG
    COMPOSER_LOG="$(mktemp)"
    if docker compose run --rm composer create-project "laravel/laravel:^${LARAVEL_VERSION}" . 2>&1 | tee "$COMPOSER_LOG"; then
        rm -f "$COMPOSER_LOG"
        success "Laravel ^${LARAVEL_VERSION} installed successfully!"

        chmod 600 "${PROJECT_DIR}/public_html/.env"

        info "Setting permissions..."
        docker compose run --rm permissions

        info "Laravel is ready to use in ${PROJECT_DIR}/public_html/"
    else
        explain_composer_failure "$COMPOSER_LOG"
        rm -f "$COMPOSER_LOG"
        error "Failed to install Laravel. Check the logs above."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Existing application from a git repository (--repo) ====================
install_from_repo() {
    local APP_DIR="${PROJECT_DIR}/public_html"
    info "Deploying the application from ${REPO_URL} (${REPO_BRANCH:-default branch})..."

    if [[ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
        error "${APP_DIR} is not empty; --repo needs an empty application directory"
    fi

    if ! command -v git &> /dev/null; then
        info "git is not installed. Installing..."
        (apt-get update -qq && apt-get install -y -qq git > /dev/null) || error "Failed to install git"
    fi

    # Private repositories: an SSH deploy key. The key is copied into the project (mode 600) so that
    # update.sh can reuse it; host keys are trusted on first use and kept in the project as well.
    local GIT_ENV=(env GIT_TERMINAL_PROMPT=0)
    local KEY_FILE=""
    if [[ -n "$DEPLOY_KEY" ]]; then
        KEY_FILE=".config/deploy_key"
        mkdir -p "${PROJECT_DIR}/.config"
        install -m 600 "$DEPLOY_KEY" "${PROJECT_DIR}/${KEY_FILE}"
        GIT_ENV+=("GIT_SSH_COMMAND=ssh -i ${PROJECT_DIR}/${KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${PROJECT_DIR}/.config/known_hosts")
    fi

    local CLONE_ARGS=(clone --quiet)
    if [[ -n "$REPO_BRANCH" ]]; then
        CLONE_ARGS+=(--branch "$REPO_BRANCH" --single-branch)
    fi
    CLONE_ARGS+=(-- "$REPO_URL" "$APP_DIR")
    if ! "${GIT_ENV[@]}" git "${CLONE_ARGS[@]}"; then
        error "Failed to clone ${REPO_URL}"
    fi

    # The permissions service sets every file to 644/755, which would show up as modified files
    # (for example the executable bit of artisan) and block update.sh. Ignore file mode changes.
    git -C "$APP_DIR" -c safe.directory="$APP_DIR" config core.fileMode false

    # Remember what was deployed: update.sh reads this file (plain KEY=VALUE lines, never sourced)
    if [[ -z "$REPO_BRANCH" ]]; then
        REPO_BRANCH=$(git -C "$APP_DIR" -c safe.directory="$APP_DIR" rev-parse --abbrev-ref HEAD)
    fi
    {
        echo "REPO_URL=${REPO_URL}"
        echo "REPO_BRANCH=${REPO_BRANCH}"
        echo "DEPLOY_KEY_FILE=${KEY_FILE}"
        echo "POST_DEPLOY=${POST_DEPLOY}"
    } > "${PROJECT_DIR}/.deploy-meta"
    chmod 600 "${PROJECT_DIR}/.deploy-meta"
    info "Cloned ${REPO_URL} at $(git -C "$APP_DIR" -c safe.directory="$APP_DIR" rev-parse --short HEAD) (branch ${REPO_BRANCH})"

    if [[ ! -f "${APP_DIR}/artisan" || ! -f "${APP_DIR}/composer.json" ]]; then
        error "The repository does not look like a Laravel application (artisan or composer.json is missing)"
    fi

    # Directories Laravel needs to write to; repositories often do not ship them
    mkdir -p "${APP_DIR}/storage/framework/cache/data" "${APP_DIR}/storage/framework/sessions" \
             "${APP_DIR}/storage/framework/views" "${APP_DIR}/storage/logs" "${APP_DIR}/bootstrap/cache"

    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"
    info "Setting permissions..."
    docker compose run --rm permissions

    info "Installing dependencies: composer install --no-dev --optimize-autoloader"
    local COMPOSER_LOG
    COMPOSER_LOG="$(mktemp)"
    if ! docker compose run --rm composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tee "$COMPOSER_LOG"; then
        explain_composer_failure "$COMPOSER_LOG"
        rm -f "$COMPOSER_LOG"
        error "composer install failed. Check the logs above."
    fi
    rm -f "$COMPOSER_LOG"

    # .env from the example, APP_KEY if the application has none yet
    if [[ ! -f "${APP_DIR}/.env" ]]; then
        local PREVIOUS_UMASK
        PREVIOUS_UMASK=$(umask)
        umask 077
        if [[ -f "${APP_DIR}/.env.example" ]]; then
            cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
        else
            : > "${APP_DIR}/.env"
        fi
        umask "$PREVIOUS_UMASK"
        chown 1000:1000 "${APP_DIR}/.env"
    fi
    chmod 600 "${APP_DIR}/.env"
    if ! grep -qE '^APP_KEY=.+' "${APP_DIR}/.env"; then
        info "Generating APP_KEY..."
        docker compose run --rm artisan key:generate --force || warn "Failed to generate APP_KEY"
    fi
    docker compose run --rm artisan storage:link 2>&1 || warn "storage:link failed (it may already exist)"

    success "Application deployed from ${REPO_URL}"
    cd "${SCRIPT_DIR}" || true
}

# ==================== Laravel .env configuration ==============
configure_laravel_env() {
    local LARAVEL_ENV="${PROJECT_DIR}/public_html/.env"

    if [[ ! -f "$LARAVEL_ENV" ]]; then
        error "Laravel .env file not found: ${LARAVEL_ENV}; deployment cannot continue"
    fi

    info "Configuring the Laravel .env file..."
    chmod 600 "$LARAVEL_ENV"
    set_env_var "$LARAVEL_ENV" APP_ENV production
    set_env_var "$LARAVEL_ENV" APP_DEBUG false

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
        DB_HOST="$(docker_bridge_ip)"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="$PORT_POSTGRES"; else DB_PORT_VALUE="$PORT_MYSQL"; fi
    else
        DB_HOST="${SLUG}_db"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="5432"; else DB_PORT_VALUE="3306"; fi
    fi

    # Laravel 11+ keeps DB_* commented out, Laravel 10 does not; handle both cases
    # set_env_var replaces a line (also a commented-out one) or appends it when the .env does not have it
    # (an existing application's .env.example may not list every DB_* setting)
    set_env_var "$LARAVEL_ENV" DB_CONNECTION "$DB_CONNECTION"
    set_env_var "$LARAVEL_ENV" DB_HOST "$DB_HOST"
    set_env_var "$LARAVEL_ENV" DB_PORT "$DB_PORT_VALUE"
    set_env_var "$LARAVEL_ENV" DB_DATABASE "$(db_env_value "$DB_NAME" laravel)"
    set_env_var "$LARAVEL_ENV" DB_USERNAME "$(db_env_value "$DB_USER" laravel)"
    set_env_var "$LARAVEL_ENV" DB_PASSWORD "$(db_env_value "$DB_PASS" laravel)"

    SITE_SCHEME=http
    set_env_var "$LARAVEL_ENV" APP_URL "http://${DOMAIN}"

    info "DB parameters and APP_URL written successfully to ${LARAVEL_ENV}:"
    info "  APP_URL: http://${DOMAIN}"
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
        error "Failed to run Laravel migrations. Deployment stopped; do not reinstall over this project. Fix the DB connection or migration, then run: cd ${PROJECT_DIR} && docker compose run --rm artisan migrate --force"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Modules: install hooks and compose services ====================
install_modules() {
    if [[ ${#ENABLED_MODULES[@]} -eq 0 ]]; then
        return
    fi

    # 1. install hooks (composer packages, artisan commands, ...)
    run_module_hook install

    # 2. services the modules add to the project's docker-compose.yml. They are added only now:
    #    a worker started before Laravel is installed would restart in a loop until artisan exists
    local NAME FN SNIPPET ADDED=false
    for NAME in "${ENABLED_MODULES[@]}"; do
        FN="$(module_fn "$NAME" compose)"
        if declare -F "$FN" > /dev/null; then
            SNIPPET=$("$FN") || error "Module $NAME failed to generate Compose configuration"
            add_compose_service "$SNIPPET"
            info "Module ${NAME}: service added to docker-compose.yml"
            ADDED=true
        fi
    done
    if [[ "$ADDED" == true ]]; then
        cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"
        # Rebuild derived services when a prior installation left an image with this slug.
        if docker compose up -d --build 2>&1; then
            success "Module services started"
        else
            error "Failed to start the module services. Check: cd ${PROJECT_DIR} && docker compose logs"
        fi
        cd "${SCRIPT_DIR}" || true
    fi
}

# ==================== Post-deploy commands ====================
run_post_deploy() {
    if [[ -z "$POST_DEPLOY" ]]; then
        return
    fi

    info "Running post-deploy commands in the php container..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"
    if docker compose exec -T -w /var/www/html php sh -c "$POST_DEPLOY"; then
        success "Post-deploy commands completed"
    else
        warn "Post-deploy commands failed. The rest of the deployment continues; the script will exit with an error at the end."
        POST_DEPLOY_FAILED=true
    fi
    cd "${SCRIPT_DIR}" || true
}

# ==================== SSL certificate issuance ===========
prepare_proxy_ssl() {
    toggle_ssl_blocks uncomment proxy
    sed -i '/# HTTPS_REDIRECT/{n;s|proxy_pass http://.*;|return 301 https://$host$request_uri;|;}' \
        "$PROXY_DIR/sites/$SLUG.conf" || error "Cannot enable the HTTPS redirect"
}
obtain_ssl_certificate() {
    if [[ "$OBTAIN_SSL" != true ]]; then
        info "Skipping SSL certificate issuance (--no-ssl given)"
        return
    fi
    info "Obtaining an SSL certificate for domain $DOMAIN..."
    cd "$PROJECT_DIR" || error "Failed to change to project directory"
    if docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
        --email "$SSL_EMAIL" --agree-tos --non-interactive; then
        local SAVED
        SAVED=$(mktemp) || error "Cannot snapshot the project Nginx configuration"
        cp "$PROJECT_DIR/.config/nginx/_site.conf" "$SAVED" || error "Cannot snapshot the project Nginx configuration"
        toggle_ssl_blocks uncomment project
        if ! docker compose run --rm --no-deps -T --entrypoint nginx nginx -t; then
            cat "$SAVED" > "$PROJECT_DIR/.config/nginx/_site.conf" || error "Cannot restore project Nginx configuration; snapshot retained at $SAVED"
            rm -f "$SAVED"
            error "Invalid project SSL configuration; HTTP configuration restored"
        fi
        if ! docker compose exec -T nginx nginx -s reload; then
            cat "$SAVED" > "$PROJECT_DIR/.config/nginx/_site.conf" || error "Cannot restore project Nginx configuration; snapshot retained at $SAVED"
            rm -f "$SAVED"
            error "Cannot reload project SSL configuration; HTTP configuration restored"
        fi
        rm -f "$SAVED"
        proxy_transaction prepare_proxy_ssl || error "Cannot apply HTTPS to the shared proxy; its previous configuration was restored"
        SITE_SCHEME=https
        set_env_var "$PROJECT_DIR/public_html/.env" APP_URL "https://$DOMAIN"
        docker compose run --rm -T artisan config:clear || error "Cannot clear Laravel configuration after enabling HTTPS"
        success "HTTPS enabled; HTTP redirects to HTTPS and ACME remains accessible"
    else
        warn "Failed to obtain an SSL certificate. The application remains available over HTTP. Check DNS and ports 80/443."
    fi
    cd "$SCRIPT_DIR" || true
}

# ==================== nginxproxy restart ===================
prepare_proxy_site() {
    init_nginxproxy
    update_proxy_nginx_conf
    update_proxy_docker_compose
    toggle_ssl_blocks comment proxy
}
restart_nginxproxy() {
    proxy_transaction prepare_proxy_site || error "Shared proxy was not changed successfully; project data retained"
}

# ==================== Send project data to the endpoint ====================
send_project_data() {
    [[ -n "$ENDPOINT" ]] || return 0
    info "Sending project data to endpoint: $ENDPOINT..."
    local DB_PORT_VALUE DB_NAME DB_USER DB_PASS RESPONSE HTTP_CODE RESPONSE_BODY
    if [[ "$DB_TYPE" == postgres ]]; then
        DB_PORT_VALUE="$PORT_POSTGRES"; DB_NAME="$DB_POSTGRES_NAME"; DB_USER="$DB_POSTGRES_USER"; DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_PORT_VALUE="$PORT_MYSQL"; DB_NAME="$DB_MYSQL_NAME"; DB_USER="$DB_MYSQL_USER"; DB_PASS="$DB_MYSQL_PASSWORD"
    fi
    local JSON_DATA
    JSON_DATA=$(printf '%s\0' "$SLUG" "$DOMAIN" "$APP_TYPE" "$LARAVEL_VERSION" "$DB_TYPE" \
        "$PORT_HTTP" "$PORT_HTTPS" "$PORT_PHP" "$PORT_REDIS" "$REDIS_PASSWORD" \
        "$DB_PORT_VALUE" "$DB_NAME" "$DB_USER" "$DB_PASS" "$ENABLE_BASIC_AUTH" "$AUTH_USER" "$AUTH_PASSWORD" \
        "$OBTAIN_SSL" "$SSL_EMAIL" "$WWW_DIR/$SLUG" | python3 "$SCRIPT_DIR/lib/endpoint.py") ||
        error "Cannot serialize endpoint JSON"
    RESPONSE=$(printf '%s' "$JSON_DATA" | curl --connect-timeout 5 --max-time 20 -X PUT \
        -H "Content-Type: application/json" --data-binary @- -w '\n%{http_code}' -sS "$ENDPOINT" 2>&1) || true
    HTTP_CODE=$(tail -n1 <<< "$RESPONSE")
    RESPONSE_BODY=$(head -n-1 <<< "$RESPONSE")
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        success "Data sent to the endpoint successfully (HTTP $HTTP_CODE)"
    else
        warn "Failed to send data to the endpoint (HTTP $HTTP_CODE)"
    fi
    [[ -z "$RESPONSE_BODY" ]] || info "Server response: $RESPONSE_BODY"
}

# ==================== Project backup archive creation ====================
create_project_backup() {
    if [[ "$CREATE_BACKUP" != true ]]; then
        return
    fi

    info "Creating a project backup archive..."

    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local ARCHIVE_DIR="${LARASHIP_ARCHIVE_DIR:-/tmp}"
    [[ "$ARCHIVE_DIR" == /* && -d "$ARCHIVE_DIR" && ! -L "$ARCHIVE_DIR" ]] || error "Archive directory must be an existing absolute real directory"
    local BACKUP_PATH="${ARCHIVE_DIR}/${SLUG}_${TIMESTAMP}.zip"

    ensure_packages zip

    local BACKUP_WORK
    BACKUP_WORK=$(mktemp -d "${ARCHIVE_DIR}/laraship-backup.XXXXXX") || error "Failed to create a private backup directory"
    info "Archiving ${PROJECT_DIR} to ${BACKUP_PATH}..."

    # Build privately, then publish with an exclusive hard link. Never follow/overwrite a /tmp path.
    if (
        umask 077
        trap 'rm -rf -- "$BACKUP_WORK"' EXIT
        trap 'exit 1' HUP INT TERM
        cd "$(dirname "${PROJECT_DIR}")" || exit 1
        zip -r -q "${BACKUP_WORK}/project.zip" "$(basename "${PROJECT_DIR}")" || exit 1
        ln -T -- "${BACKUP_WORK}/project.zip" "${BACKUP_PATH}"
    ); then
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
    if [[ -n "$REPO_URL" ]]; then
        echo "APPLICATION:"
        echo "  Repository:     ${REPO_URL}"
        echo "  Branch:         ${REPO_BRANCH}"
        echo "  Update later:   sudo bash ${SCRIPT_DIR}/update.sh --slug ${SLUG}"
        echo ""
    fi
    if [[ "$BIND_LOCAL" == true || -n "$PHP_UPLOAD_MAX" ]]; then
        echo "OPTIONS:"
        [[ "$BIND_LOCAL" == true ]]     && echo "  --bind-local:       HTTP/HTTPS, Redis and DB ports are bound to 127.0.0.1"
        [[ -n "$PHP_UPLOAD_MAX" ]]      && echo "  --php-upload-max:   upload_max_filesize = post_max_size = ${PHP_UPLOAD_MAX}"
        echo ""
    fi
    run_module_hook summary
    echo "============================================================"
    echo "Next steps:"
    echo "============================================================"
    if [[ "$OBTAIN_SSL" == true ]]; then
        echo "  1. Restart the proxy to apply the SSL certificate:"
        echo "       cd ${PROXY_DIR} && docker compose restart"
        echo ""
        echo "  2. Check that the site is reachable:"
        echo "       ${SITE_SCHEME:-http}://${DOMAIN}"
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
        case "$ARG" in
            -h|--help)       usage; exit 0 ;;
            -V|--version)    echo "deploy-laravel.sh ${SCRIPT_VERSION}"; exit 0 ;;
            --list-modules)  list_modules; exit 0 ;;
            --list-presets)  list_presets; exit 0 ;;
        esac
    done

    load_versions

    # --config FILE, --preset NAME and --dry-run are handled here. Settings are applied in this order,
    # a later one overriding an earlier one: presets, the --config file, the command line
    local CLI_ARGS=() PRESET_NAMES=() NAME I=1
    while [[ $I -le $# ]]; do
        case "${!I}" in
            --config)
                [[ -z "$USED_CONFIG" ]] || error "--config can be given only once"
                I=$((I + 1))
                [[ $I -le $# ]] || error "--config requires a file"
                USED_CONFIG="${!I}" ;;
            --preset)
                I=$((I + 1))
                [[ $I -le $# ]] || error "--preset requires a name"
                PRESET_NAMES+=("${!I}") ;;
            --dry-run)
                DRY_RUN=true ;;
            *)
                CLI_ARGS+=("${!I}") ;;
        esac
        I=$((I + 1))
    done

    # A dry run only reads and validates, so it needs neither root nor /var/www
    if [[ "$DRY_RUN" != true ]]; then
        check_root
        ensure_www_dir
    fi
    for NAME in ${PRESET_NAMES[@]+"${PRESET_NAMES[@]}"}; do
        load_preset "$NAME"
    done
    if [[ -n "$USED_CONFIG" ]]; then
        info "Reading settings from ${USED_CONFIG}..."
        read_config_file "$USED_CONFIG"
    fi
    LARAVEL_VERSION="$DEFAULT_LARAVEL_VERSION"
    info "Parsing arguments..."
    parse_args ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} ${CLI_ARGS[@]+"${CLI_ARGS[@]}"}
    if [[ "${LARASHIP_CONTAINER:-0}" == 1 && "$DB_NATIVE" == true && "$DRY_RUN" != true ]]; then
        error "Native database provisioning requires the native Bash runner on the server; use a container database with the Docker runner"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run
        exit 0
    fi
    runtime_require python3 ss flock curl timeout
    project_lock
    check_project_target
    assign_ports
    validate_port_values
    check_port_availability
    info "Arguments processed successfully"
    install_docker
    create_project
    create_dhparam
    comment_ssl_blocks
    create_native_database
    build_and_start_project
    if [[ -n "$REPO_URL" ]]; then
        install_from_repo
    else
        install_laravel
    fi
    configure_laravel_env
    run_module_hook env "${PROJECT_DIR}/public_html/.env"
    install_modules
    run_post_deploy
    check_project_http
    restart_nginxproxy
    obtain_ssl_certificate
    send_project_data
    create_project_backup
    print_summary
    if [[ "$POST_DEPLOY_FAILED" == true ]]; then
        error "The deployment finished, but the --post-deploy commands failed (see above)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
