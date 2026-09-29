#!/usr/bin/env bats
# End-to-end: a real deploy-laravel.sh deployment, checking that the created site
# matches the arguments passed, followed by the project lifecycle.
#
# WARNING: the test writes to /var/www, takes ports 80/443 and creates Docker
# resources. Run it only in a disposable environment (a CI runner or
# tests/run-local.sh) and only with E2E_ALLOW=1. The tests run in order and
# depend on each other.
#
# Parameters (environment variables):
#   E2E_ALLOW=1             required, a guard against running on a live server
#   E2E_DB=postgres|mysql   database type (default: postgres)
#   E2E_FILAMENT=1|0        install Filament (default: 1)
#   E2E_LARAVEL=X.Y         Laravel version; empty = the script's default
#   E2E_SSL=1|0             request a certificate instead of --no-ssl (without DNS
#                           it will not be issued: the test checks that the
#                           script only warns)

load helpers

E2E_DB="${E2E_DB:-postgres}"
E2E_FILAMENT="${E2E_FILAMENT:-1}"
E2E_LARAVEL="${E2E_LARAVEL:-}"
E2E_SSL="${E2E_SSL:-0}"

SLUG="e2e${E2E_DB}"
DOMAIN="${SLUG}.example.test"
PROJECT="/var/www/${SLUG}"
PORT_HTTP=18080 PORT_HTTPS=18443 PORT_PHP=19000 PORT_REDIS=16379 PORT_DB=15432
REDIS_PASS="Rpass_123" DB_NAME="e2edb" DB_USER="e2euser" DB_PASS="Dbpass_123"
FIL_EMAIL="admin@example.test" FIL_NAME="E2EAdmin" FIL_PASS="Passw0rd_123"
AUTH_USER="e2euser" AUTH_PASS="Tpass_123"

# ---------- helpers ----------

env_val() { grep -E "^$2=" "$1" | head -n1 | cut -d= -f2-; }

# The project's docker compose, without a TTY.
dc() { docker compose --project-directory "${PROJECT}" -f "${PROJECT}/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }

# Retry a command until it succeeds (up to N seconds).
eventually() {
    local timeout="$1"; shift
    local i
    for ((i = 0; i < timeout; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    "$@"
}

container_up() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# ---------- setup ----------

setup_file() {
    [ "${E2E_ALLOW:-}" = "1" ] || skip "e2e writes to /var/www and takes ports 80/443: run with E2E_ALLOW=1 in a disposable environment"
    [ "$(id -u)" -eq 0 ] || skip "root is required"

    local ssl_args=(--no-ssl)
    [ "${E2E_SSL}" = "1" ] && ssl_args=(--ssl-email admin@example.test)

    local args=(
        --slug "${SLUG}" --domain "${DOMAIN}" --db-type "${E2E_DB}"
        --port-http "${PORT_HTTP}" --port-https "${PORT_HTTPS}" --port-php "${PORT_PHP}"
        --port-redis "${PORT_REDIS}" --redis-password "${REDIS_PASS}"
        --enable-basic-auth --auth-user "${AUTH_USER}" --auth-password "${AUTH_PASS}"
        --create-backup
        "${ssl_args[@]}"
    )
    if [ "${E2E_DB}" = "postgres" ]; then
        args+=(--port-postgres "${PORT_DB}" --db-postgres-name "${DB_NAME}"
               --db-postgres-user "${DB_USER}" --db-postgres-password "${DB_PASS}")
    else
        args+=(--port-mysql "${PORT_DB}" --db-mysql-name "${DB_NAME}"
               --db-mysql-user "${DB_USER}" --db-mysql-password "${DB_PASS}"
               --db-mysql-root-password "Root_${DB_PASS}")
    fi
    [ -n "${E2E_LARAVEL}" ] && args+=(--laravel-version "${E2E_LARAVEL}")
    if [ "${E2E_FILAMENT}" = "1" ]; then
        args+=(--install-filament --filament-email "${FIL_EMAIL}"
               --filament-name "${FIL_NAME}" --filament-password "${FIL_PASS}")
    fi

    export DEPLOY_LOG="${BATS_FILE_TMPDIR}/deploy.log"
    set +e
    bash "${DEPLOY}" "${args[@]}" >"${DEPLOY_LOG}" 2>&1
    echo "$?" >"${BATS_FILE_TMPDIR}/deploy.exit"
    set -e
}

teardown_file() {
    # Safety net: remove the project even if the lifecycle tests failed early.
    if [ -d "${PROJECT}" ]; then
        (cd "${PROJECT}" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
        rm -rf "${PROJECT}"
    fi
    rm -f "/var/www/nginxproxy/sites/${SLUG}.conf" "/var/www/nginxproxy/sites/${SLUG}.conf.disabled"
    if [ -f "${BATS_FILE_TMPDIR}/deploy.log" ] && [ -n "${E2E_KEEP_LOG:-}" ]; then
        cp "${BATS_FILE_TMPDIR}/deploy.log" "${E2E_KEEP_LOG}" || true
    fi
}

# ---------- what the script produced ----------

@test "the script exited with code 0 and printed the summary" {
    [ "$(cat "${BATS_FILE_TMPDIR}/deploy.exit")" = "0" ] || {
        tail -n 40 "${DEPLOY_LOG}" | strip_ansi >&2
        return 1
    }
    strip_ansi <"${DEPLOY_LOG}" | grep -q "Deployment completed"
}

@test "the log contains no ERROR messages" {
    if strip_ansi <"${DEPLOY_LOG}" | grep -qE '^\[ERROR\]'; then return 1; fi
}

@test "project containers are running" {
    for c in php nginx redis cron certbot_renew; do
        container_up "${SLUG}_${c}" || { echo "${SLUG}_${c} is not running" >&2; return 1; }
    done
    container_up "${SLUG}_db"
}

@test "the shared nginxproxy is running on 80/443" {
    container_up nginxproxy
    [ -f "/var/www/nginxproxy/sites/${SLUG}.conf" ]
    grep -q "server_name ${DOMAIN};" "/var/www/nginxproxy/sites/${SLUG}.conf"
}

@test "ports match the arguments" {
    docker port "${SLUG}_nginx" 80 | grep -q ":${PORT_HTTP}$"
    docker port "${SLUG}_nginx" 443 | grep -q ":${PORT_HTTPS}$"
    docker port "${SLUG}_php" 9000 | grep -q "127.0.0.1:${PORT_PHP}$"
    docker port "${SLUG}_redis" 6379 | grep -q ":${PORT_REDIS}$"
    local db_inner=5432
    [ "${E2E_DB}" = "mysql" ] && db_inner=3306
    docker port "${SLUG}_db" "${db_inner}" | grep -q ":${PORT_DB}$"
}

@test "the project .env matches the arguments" {
    local f="${PROJECT}/.env"
    [ "$(env_val "$f" SITE_HOST)" = "${DOMAIN}" ]
    [ "$(env_val "$f" SITE_PORT_HTTP)" = "${PORT_HTTP}" ]
    [ "$(env_val "$f" SITE_PORT_HTTPS)" = "${PORT_HTTPS}" ]
    [ "$(env_val "$f" PHP_PORT)" = "${PORT_PHP}" ]
    [ "$(env_val "$f" REDIS_PORT)" = "${PORT_REDIS}" ]
    [ "$(env_val "$f" REDIS_PASSWORD)" = "${REDIS_PASS}" ]
    if [ "${E2E_DB}" = "postgres" ]; then
        [ "$(env_val "$f" DB_POSTGRES_NAME)" = "${DB_NAME}" ]
        [ "$(env_val "$f" DB_POSTGRES_USER)" = "${DB_USER}" ]
        [ "$(env_val "$f" DB_POSTGRES_PASSWORD)" = "${DB_PASS}" ]
    else
        [ "$(env_val "$f" DB_MYSQL_NAME)" = "${DB_NAME}" ]
        [ "$(env_val "$f" DB_MYSQL_USER)" = "${DB_USER}" ]
        [ "$(env_val "$f" DB_MYSQL_PASSWORD)" = "${DB_PASS}" ]
    fi
}

@test "Laravel .env: driver, DB host and APP_URL" {
    local f="${PROJECT}/public_html/.env"
    local drv=pgsql
    [ "${E2E_DB}" = "mysql" ] && drv=mysql
    [ "$(env_val "$f" DB_CONNECTION)" = "${drv}" ]
    [ "$(env_val "$f" DB_HOST)" = "${SLUG}_db" ]
    [ "$(env_val "$f" DB_DATABASE)" = "${DB_NAME}" ]
    [ "$(env_val "$f" DB_USERNAME)" = "${DB_USER}" ]
    [ "$(env_val "$f" DB_PASSWORD)" = "${DB_PASS}" ]
    [ "$(env_val "$f" APP_URL)" = "https://${DOMAIN}" ]
}

@test "the requested Laravel version is installed" {
    run art --version
    [ "${status}" -eq 0 ]
    if [ -n "${E2E_LARAVEL}" ]; then
        [[ "${output}" == *"Laravel Framework ${E2E_LARAVEL%%.*}."* ]]
    else
        [[ "${output}" == *"Laravel Framework"* ]]
    fi
}

@test "migrations ran, the database is of the right type" {
    run art migrate:status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"create_users_table"*"Ran"* ]]

    run art tinker --execute='echo DB::connection()->getDriverName();'
    if [ "${E2E_DB}" = "postgres" ]; then [[ "${output}" == *pgsql* ]]; else [[ "${output}" == *mysql* ]]; fi
}

@test "Redis answers with the given password" {
    run docker exec "${SLUG}_redis" redis-cli -a "${REDIS_PASS}" ping
    [[ "${output}" == *PONG* ]]
}

@test "Basic Auth: the .htpasswd entry is valid" {
    local line hash salt
    line="$(grep "^${AUTH_USER}:" "${PROJECT}/.config/nginx/.htpasswd")"
    [ -n "${line}" ]
    hash="${line#*:}"                       # $apr1$SALT$HASH
    salt="$(printf '%s' "${hash}" | cut -d'$' -f3)"
    [ "$(openssl passwd -apr1 -salt "${salt}" "${AUTH_PASS}")" = "${hash}" ]
}

@test "Filament: package, admin user and password match the arguments" {
    [ "${E2E_FILAMENT}" = "1" ] || skip "Filament was not requested"
    grep -q '"filament/filament": "^5' "${PROJECT}/public_html/composer.json"
    [ "$(env_val "${PROJECT}/.env" FILAMENT_ADMIN_EMAIL)" = "${FIL_EMAIL}" ]
    run art tinker --execute="\$u = App\\Models\\User::where('email','${FIL_EMAIL}')->first(); echo \$u ? \$u->name.'|'.(Hash::check('${FIL_PASS}', \$u->password) ? 'PASS_OK' : 'PASS_BAD') : 'NO_USER';"
    [[ "${output}" == *"${FIL_NAME}|PASS_OK"* ]]
}

@test "the application answers over HTTP (artisan serve inside the php container)" {
    docker exec -d -w /var/www/html "${SLUG}_php" php artisan serve --host=127.0.0.1 --port=8000 --no-reload
    code() { docker exec "${SLUG}_php" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8000$1"; }
    http_is() { [ "$(code "$1")" = "$2" ]; }
    eventually 30 http_is / 200
    if [ "${E2E_FILAMENT}" = "1" ]; then
        http_is /admin/login 200
        http_is /admin 302
    fi
}

@test "SSL: without DNS the script only warns; with --no-ssl the block stays commented out" {
    local log; log="$(strip_ansi <"${DEPLOY_LOG}")"
    if [ "${E2E_SSL}" = "1" ]; then
        [[ "${log}" == *"Failed to obtain an SSL certificate"* ]]
    else
        [[ "${log}" == *"Skipping SSL certificate issuance"* ]]
    fi
    # Without a certificate the HTTPS block stays commented out and nginx keeps running.
    grep -qE '^#\s*listen 443' "${PROJECT}/.config/nginx/_site.conf"
    container_up "${SLUG}_nginx"
}

@test "backup: the zip exists, contains the project, and its path is stored in .env" {
    local zip; zip="$(env_val "${PROJECT}/.env" BACKUP_ARCHIVE_PATH)"
    [ -f "${zip}" ]
    run python3 -c "import sys,zipfile; n=zipfile.ZipFile(sys.argv[1]).namelist(); sys.exit(0 if any(x.endswith('public_html/artisan') for x in n) else 1)" "${zip}"
    [ "${status}" -eq 0 ]
}

# ---------- lifecycle ----------

@test "list-projects shows the project" {
    run bash "${REPO_ROOT}/list-projects.sh"
    [ "${status}" -eq 0 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"${SLUG}"* ]]
}

@test "deactivate: containers are stopped, the proxy config is disabled" {
    run bash "${REPO_ROOT}/deactivate.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    if container_up "${SLUG}_php"; then return 1; fi
    [ -f "/var/www/nginxproxy/sites/${SLUG}.conf.disabled" ]
    [ ! -f "/var/www/nginxproxy/sites/${SLUG}.conf" ]
    container_up nginxproxy
}

@test "activate: the project is up, the proxy config is restored" {
    run bash "${REPO_ROOT}/activate.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    eventually 60 container_up "${SLUG}_php"
    container_up "${SLUG}_nginx"
    [ -f "/var/www/nginxproxy/sites/${SLUG}.conf" ]
    container_up nginxproxy
}

@test "remove: deletes containers, volumes, network, proxy config and folder" {
    run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}'"
    [ "${status}" -eq 0 ]
    [ ! -d "${PROJECT}" ]
    [ -z "$(docker ps -aq --filter "name=${SLUG}_")" ]
    [ -z "$(docker volume ls -q --filter "name=${SLUG}_")" ]
    if docker network inspect "${SLUG}" >/dev/null 2>&1; then return 1; fi
    [ ! -e "/var/www/nginxproxy/sites/${SLUG}.conf" ]
    [ ! -e "/var/www/nginxproxy/sites/${SLUG}.conf.disabled" ]
    if grep -q "${SLUG}" /var/www/nginxproxy/docker-compose.yml; then return 1; fi
}
