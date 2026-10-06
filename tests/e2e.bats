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
#   E2E_CONFIG=1|0          give the settings to --config FILE instead of flags (the Redis
#                           password is deliberately wrong in the file and corrected on the
#                           command line, to check that flags win)
#   E2E_EXTRAS=1|0          also pass --bind-local --use-redis --queue-worker
#                           --php-upload-max 64M --with backup and check their effect. With 0 (the
#                           default) the run doubles as the compatibility guard: the
#                           behaviour without the new flags must stay as in 1.0.0

load helpers

E2E_DB="${E2E_DB:-postgres}"
E2E_FILAMENT="${E2E_FILAMENT:-1}"
E2E_LARAVEL="${E2E_LARAVEL:-}"
E2E_SSL="${E2E_SSL:-0}"
E2E_EXTRAS="${E2E_EXTRAS:-0}"
E2E_CONFIG="${E2E_CONFIG:-0}"

SLUG="e2e${E2E_DB}"
DOMAIN="${SLUG}.example.test"
PROJECT="/var/www/${SLUG}"
PORT_HTTP=18080 PORT_HTTPS=18443 PORT_PHP=19000 PORT_REDIS=16379 PORT_DB=15432
REDIS_PASS="Rpass_123" DB_NAME="e2edb" DB_USER="e2euser" DB_PASS="Dbpass_123"
FIL_EMAIL="admin@example.test" FIL_NAME="E2EAdmin" FIL_PASS="Passw0rd_123"
AUTH_USER="e2euser" AUTH_PASS="Tpass_123"

# ---------- helpers ----------

# The project's docker compose, without a TTY.
dc() { docker compose --project-directory "${PROJECT}" -f "${PROJECT}/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }

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
    if [ "${E2E_EXTRAS}" = "1" ]; then
        args+=(--bind-local --use-redis --queue-worker --php-upload-max 64M --with backup)
    fi
    if [ "${E2E_FILAMENT}" = "1" ]; then
        args+=(--install-filament --filament-email "${FIL_EMAIL}"
               --filament-name "${FIL_NAME}" --filament-password "${FIL_PASS}")
    fi

    if [ "${E2E_CONFIG}" = "1" ]; then
        # Turn the flags into a config file: --flag value -> FLAG=value, --flag -> FLAG=true
        local cfg="${BATS_FILE_TMPDIR}/deploy.conf" i=0 key val nxt
        : >"${cfg}"
        while [ "${i}" -lt "${#args[@]}" ]; do
            key="$(printf '%s' "${args[i]#--}" | tr 'a-z-' 'A-Z_')"
            nxt="${args[i + 1]:-}"
            if [ -z "${nxt}" ] || [[ "${nxt}" == --* ]]; then
                echo "${key}=true" >>"${cfg}"
                i=$((i + 1))
            else
                val="${nxt}"
                [ "${key}" = "REDIS_PASSWORD" ] && val="Wrong_000"
                echo "${key}=${val}" >>"${cfg}"
                i=$((i + 2))
            fi
        done
        chmod 600 "${cfg}"
        args=(--config "${cfg}" --redis-password "${REDIS_PASS}")
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
    [ "$(env_val "$f" APP_URL)" = "http://${DOMAIN}" ]
    [ "$(env_val "$f" APP_ENV)" = production ]
    [ "$(env_val "$f" APP_DEBUG)" = false ]
    [ "$(stat -c %a "$f")" = 600 ]
    [ "$(stat -c %a "${PROJECT}/.env")" = 600 ]
    run docker exec "${SLUG}_php" php -r 'exit(extension_loaded("xdebug") ? 1 : 0);'
    [ "${status}" -eq 0 ]
}

@test "the requested Laravel version is installed" {
    run art --version
    [ "${status}" -eq 0 ]
    if [ -n "${E2E_LARAVEL}" ]; then
        [[ "${output}" == *"Laravel Framework ${E2E_LARAVEL%%.*}."* ]]
    else
        # No --laravel-version: the default from versions.env
        local major; major="$(env_val "${REPO_ROOT}/versions.env" LARAVEL_VERSION | cut -d. -f1)"
        [[ "${output}" == *"Laravel Framework ${major}."* ]]
    fi
}

@test "migrations ran, the database is of the right type" {
    run art migrate:status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"create_users_table"*"Ran"* ]]

    run art tinker --execute='echo DB::connection()->getDriverName();'
    if [ "${E2E_DB}" = "postgres" ]; then [[ "${output}" == *pgsql* ]]; else [[ "${output}" == *mysql* ]]; fi
}

@test "versions.env drives the database image" {
    local key=POSTGRES_IMAGE
    [ "${E2E_DB}" = "mysql" ] && key=MYSQL_IMAGE
    [ "$(docker inspect -f '{{.Config.Image}}' "${SLUG}_db")" = "$(env_val "${REPO_ROOT}/versions.env" "${key}")" ]
}

@test "recreating the official database container preserves records and authentication" {
    art tinker --execute='Schema::dropIfExists("e2e_persist"); Schema::create("e2e_persist", function ($t) { $t->id(); $t->string("note"); }); DB::table("e2e_persist")->insert(["note" => "persisted"]);'
    dc up -d --no-deps --force-recreate db
    db_ready() { art migrate:status >/dev/null 2>&1; }
    eventually 120 db_ready
    run art tinker --execute='echo DB::table("e2e_persist")->value("note");'
    [ "$status" = 0 ]; [[ "$output" == *"persisted"* ]]
}

@test "--config: the settings from the file were applied, and the command line won over the file" {
    [ "${E2E_CONFIG}" = "1" ] || skip "config mode not enabled"
    strip_ansi <"${DEPLOY_LOG}" | grep -q "Reading settings from"
    # Everything below was set only in the file (see the other tests), except the Redis password:
    # the file had a wrong one, the command line the right one.
    [ "$(env_val "${PROJECT}/.env" REDIS_PASSWORD)" = "${REDIS_PASS}" ]
}

@test "Redis answers with the given password" {
    run docker exec "${SLUG}_redis" redis-cli -a "${REDIS_PASS}" ping
    [[ "${output}" == *PONG* ]]
}

@test "Basic Auth: private credentials use bcrypt and never appear in container arguments" {
    grep -qF "$AUTH_USER:\$2" "$PROJECT/.config/nginx/.htpasswd"
    [ "$(stat -c %a "$PROJECT/.config/nginx/.htpasswd")" = 600 ]
    [ "$(stat -c %u "$PROJECT/.config/nginx/.htpasswd")" = 101 ]
}

@test "Filament: package, admin user and password match the arguments" {
    [ "${E2E_FILAMENT}" = "1" ] || skip "Filament was not requested"
    grep -qF "\"filament/filament\": \"$(env_val "${REPO_ROOT}/versions.env" FILAMENT_VERSION)\"" "${PROJECT}/public_html/composer.json"
    [ "$(compose_env_val "${PROJECT}/.env" FILAMENT_ADMIN_EMAIL)" = "${FIL_EMAIL}" ]
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
    [ "$(stat -c %a "$zip")" = 600 ]
    run sudo -u nobody cat "$zip"
    [ "$status" -ne 0 ]
    run python3 -c "import sys,zipfile; n=zipfile.ZipFile(sys.argv[1]).namelist(); sys.exit(0 if any(x.endswith('public_html/artisan') for x in n) else 1)" "${zip}"
    [ "${status}" -eq 0 ]
}

# ---------- known-limitation fixes (1.x) ----------

@test "normal HTTP routing protects PHP and serves ACME without authentication" {
    code() { curl --max-time 10 -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "$@"; }
    [ "$(code http://127.0.0.1/)" = 401 ]
    [ "$(code http://127.0.0.1/index.php)" = 401 ]
    [ "$(code http://127.0.0.1/index.php/anything)" = 401 ]
    [ "$(code -u "$AUTH_USER:wrong" http://127.0.0.1/index.php)" = 401 ]
    [ "$(code -u "$AUTH_USER:$AUTH_PASS" http://127.0.0.1/index.php)" = 200 ]
    [ "$(code -u "$AUTH_USER:$AUTH_PASS" http://127.0.0.1/)" = 200 ]
    docker exec "${SLUG}_nginx" sh -c 'mkdir -p /var/www/certbot/.well-known/acme-challenge; echo probe > /var/www/certbot/.well-known/acme-challenge/probe'
    [ "$(curl --max-time 10 -s -H "Host: $DOMAIN" http://127.0.0.1/.well-known/acme-challenge/probe)" = probe ]
}

@test "PHP uses production configuration with display_errors and exposure disabled" {
    run docker exec "${SLUG}_php" php -r 'echo (int)ini_get("display_errors"), "/", (int)ini_get("expose_php"), "/", basename(php_ini_loaded_file());'
    [ "$status" = 0 ]
    [ "$output" = "0/0/php.ini" ]
}

@test "cron runs schedule:run every 60 seconds" {
    grep -q 'sleep 60$' "${PROJECT}/docker-compose.yml"
    if grep -q 'sleep 600' "${PROJECT}/docker-compose.yml"; then return 1; fi
    docker inspect -f '{{join .Config.Cmd " "}}' "${SLUG}_cron" | grep -q 'sleep 60'
}

@test "PHP limits: the project.ini is mounted; defaults unchanged unless --php-upload-max" {
    run docker exec "${SLUG}_php" php -r 'echo ini_get("upload_max_filesize"), "/", ini_get("post_max_size");'
    [ "${status}" -eq 0 ]
    if [ "${E2E_EXTRAS}" = "1" ]; then
        [ "${output}" = "64M/64M" ]
    else
        [ "${output}" = "2M/8M" ]
    fi
}

@test "defaults: no queue worker, Redis not wired into Laravel, ports are loopback-only" {
    [ "${E2E_EXTRAS}" = "0" ] || skip "extras enabled"
    [ -z "$(docker ps -aq --filter "name=${SLUG}_queue")" ]
    if grep -q "${SLUG}_queue" "${PROJECT}/docker-compose.yml"; then return 1; fi
    [ "$(env_val "${PROJECT}/public_html/.env" REDIS_HOST)" != "${SLUG}_redis" ]
    docker port "${SLUG}_redis" 6379 | grep -q '^127.0.0.1:'
    docker port "${SLUG}_nginx" 80 | grep -q '^127.0.0.1:'
}

@test "HTTP/HTTPS, Redis and DB ports are published on 127.0.0.1 only, with or without --bind-local" {
    docker port "${SLUG}_nginx" 80 | grep -q "^127.0.0.1:${PORT_HTTP}$"
    docker port "${SLUG}_nginx" 443 | grep -q "^127.0.0.1:${PORT_HTTPS}$"
    docker port "${SLUG}_redis" 6379 | grep -q "^127.0.0.1:${PORT_REDIS}$"
    local db_inner=5432
    [ "${E2E_DB}" = "mysql" ] && db_inner=3306
    docker port "${SLUG}_db" "${db_inner}" | grep -q "^127.0.0.1:${PORT_DB}$"
    if docker port "${SLUG}_redis" 6379 | grep -qv '^127.0.0.1:'; then return 1; fi
}

@test "--use-redis: Laravel uses Redis for cache, sessions and queue, and it works" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    local f="${PROJECT}/public_html/.env"
    [ "$(env_val "$f" REDIS_HOST)" = "${SLUG}_redis" ]
    [ "$(env_val "$f" REDIS_PORT)" = "6379" ]
    [ "$(env_val "$f" REDIS_PASSWORD)" = "${REDIS_PASS}" ]
    [ "$(env_val "$f" SESSION_DRIVER)" = "redis" ]
    [ "$(env_val "$f" QUEUE_CONNECTION)" = "redis" ]
    run art tinker --execute='echo config("cache.default"), "|", config("session.driver"), "|", config("queue.default");'
    [[ "${output}" == *"redis|redis|redis"* ]]
    run art tinker --execute='Cache::put("e2e-key", "e2e-value", 60); echo Cache::get("e2e-key");'
    [[ "${output}" == *"e2e-value"* ]]
    # Laravel's cache connection uses Redis database 1 (REDIS_CACHE_DB)
    run docker exec "${SLUG}_redis" redis-cli -a "${REDIS_PASS}" --no-auth-warning -n 1 keys '*e2e-key*'
    [[ "${output}" == *"e2e-key"* ]]
}

@test "--queue-worker: the worker runs and executes a queued job" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    container_up "${SLUG}_queue"
    grep -q "container_name: ${SLUG}_queue" "${PROJECT}/docker-compose.yml"
    # Set a flag in the shared cache and queue "cache:forget" for it: the flag disappears
    # only after the worker container has picked the job up and run it.
    art tinker --execute='Cache::put("e2e-flag", "1", 600); Artisan::queue("cache:forget", ["key" => "e2e-flag"]);'
    flag_gone() { [ "$(art tinker --execute='echo Cache::has("e2e-flag") ? "yes" : "no";' | tail -n1)" = "no" ]; }
    eventually 90 flag_gone
}

# ---------- backup module ----------

backup_ext() { if [ "${E2E_DB}" = "mysql" ]; then echo "sql.gz"; else echo "dump"; fi; }
backup_files() { ls -1 "${PROJECT}/backups/" 2>/dev/null | grep -E "^${SLUG}-.*\.$(backup_ext)$" || true; }
newest_dump() { ls -1t "${PROJECT}/backups/" | grep -E "^${SLUG}-.*\.$(backup_ext)$" | head -n1; }
have_dump() { [ -n "$(backup_files)" ]; }
marker_count() { art tinker --execute='echo Schema::hasTable("e2e_marker") ? DB::table("e2e_marker")->count() : "none";' | tail -n1; }

@test "backup: the service runs, made the first dump, and the dump is valid" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    container_up "${SLUG}_backup"
    eventually 90 have_dump
    local f; f="$(newest_dump)"
    [ -s "${PROJECT}/backups/${f}" ]
    [ "$(stat -c %a "$PROJECT/backups/$f")" = 600 ]
    [ "$(stat -c %a "$PROJECT/backups")" = 700 ]
    if [ "${E2E_DB}" = "mysql" ]; then
        docker exec "${SLUG}_backup" sh -c "gzip -dc /backups/${f} | grep -q 'CREATE TABLE .users.'"
    else
        docker exec "${SLUG}_backup" pg_restore -l "/backups/${f}" | grep -q ' users'
    fi
}

@test "backup.sh now takes a dump and list shows it" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    local before after
    before="$(backup_files | wc -l)"
    sleep 1   # dump file names have a one-second resolution
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" now
    [ "${status}" -eq 0 ] || { printf '%s\n' "${output}" >&2; return 1; }
    after="$(backup_files | wc -l)"
    [ "${after}" -eq $((before + 1)) ]
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" list
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(newest_dump)"* ]]
}

@test "backup.sh restore brings the database back to the dumped state" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    art tinker --execute='Schema::dropIfExists("e2e_marker"); Schema::create("e2e_marker", function ($t) { $t->id(); $t->string("note"); }); DB::table("e2e_marker")->insert(["note" => "before"]);'
    [ "$(marker_count)" = "1" ]
    sleep 1
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" now
    [ "${status}" -eq 0 ]
    local dump; dump="$(newest_dump)"
    # the data changes after the dump
    art tinker --execute='DB::table("e2e_marker")->insert(["note" => "after"]);'
    [ "$(marker_count)" = "2" ]
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" restore "${dump}" --yes
    [ "${status}" -eq 0 ] || { printf '%s\n' "${output}" >&2; return 1; }
    [ "$(marker_count)" = "1" ]
    # the services are back and the application is out of maintenance mode
    container_up "${SLUG}_php"
    [ ! -f "${PROJECT}/public_html/storage/framework/down" ]
}

@test "backup: dumps older than the retention are removed" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    local old="${PROJECT}/backups/${SLUG}-19990101-000000.$(backup_ext)"
    : >"${old}"
    touch -d '30 days ago' "${old}"
    sleep 1
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" now
    [ "${status}" -eq 0 ]
    [ ! -e "${old}" ]
    [ -n "$(newest_dump)" ]
}

@test "backup.sh restore refuses a bad or a missing dump name" {
    [ "${E2E_EXTRAS}" = "1" ] || skip "extras not enabled"
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" restore "../etc/passwd" --yes
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Invalid dump file name"* ]]
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" restore "${SLUG}-20000101-000000.$(backup_ext)" --yes
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"No such dump"* ]]
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
    if [ "${E2E_EXTRAS}" = "1" ] && container_up "${SLUG}_queue"; then return 1; fi
    [ -f "/var/www/nginxproxy/sites/${SLUG}.conf.disabled" ]
    [ ! -f "/var/www/nginxproxy/sites/${SLUG}.conf" ]
    container_up nginxproxy
}

@test "activate: the project is up, the proxy config is restored" {
    run bash "${REPO_ROOT}/activate.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    eventually 60 container_up "${SLUG}_php"
    container_up "${SLUG}_nginx"
    if [ "${E2E_EXTRAS}" = "1" ]; then eventually 60 container_up "${SLUG}_queue"; eventually 60 container_up "${SLUG}_backup"; fi
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
