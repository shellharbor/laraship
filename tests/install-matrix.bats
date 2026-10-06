#!/usr/bin/env bats
# Install matrix: does Laravel install and run under different conditions?
#
# One case per run, chosen with INSTALL_CASE. Every case is a real deployment that is checked for a
# working application, then removed. "fail" cases must stop cleanly with a clear message.
#
#   laravel12-postgres      Laravel 12.x, PostgreSQL in a container
#   laravel13-mysql         the default Laravel version (versions.env), MySQL in a container
#   laravel13-filament      the default Laravel version + the Filament module (PostgreSQL)
#   laravel12-filament      Laravel 12.x + the Filament module (MySQL)
#   native-postgres         Laravel 12.x with a PostgreSQL installed on the host (--db-native)
#   native-mysql            Laravel 12.x with a MySQL installed on the host (--db-native)
#   repo-blocked-10.x       an application of the 10.x branch with --repo: composer install is refused; fails cleanly
#   repo-blocked-11.x       the same for the 11.x branch
#   laravel99-fails         a Laravel version that does not exist: must fail cleanly
#
# Deploying an existing application from a supported branch (--repo on 12.x, 13.x) is covered by
# tests/e2e-repo.bats (E2E_BRANCH). Laravel 10.x and 11.x are refused up front by --laravel-version
# (tests/validation.bats). The repo-blocked-* cases are applications on those branches: --repo cannot
# check their version, so Composer refuses them because of unfixed security advisories, and the script
# must explain it. If Packagist or Composer change that, these cases fail and show it.
#
# WARNING: like e2e.bats this writes to /var/www, takes ports 80/443 and creates Docker resources.
# The native-* cases also reconfigure the system PostgreSQL / MySQL (tests/native-db.sh). Run it only
# in a disposable environment (tests/run-local.sh install, or a CI runner) and only with E2E_ALLOW=1.

load helpers

CASE="${INSTALL_CASE:-}"
LARAVEL=""          # empty = the default of versions.env
DBT="postgres"
EXTRA=()
MODE="ok"           # ok | fail
FAIL_TEXT=""
NATIVE=""
REPO_BRANCH=""

case "${CASE}" in
    laravel12-postgres)   LARAVEL="12.0"; DBT="postgres" ;;
    laravel13-mysql)      LARAVEL="";     DBT="mysql" ;;
    laravel13-filament)   LARAVEL="";     DBT="postgres"; EXTRA=(--with filament) ;;
    laravel12-filament)   LARAVEL="12.0"; DBT="mysql";    EXTRA=(--with filament) ;;
    native-postgres)      LARAVEL="12.0"; DBT="postgres"; EXTRA=(--db-native); NATIVE="postgres" ;;
    native-mysql)         LARAVEL="12.0"; DBT="mysql";    EXTRA=(--db-native --db-root-password Root_e2e_1); NATIVE="mysql" ;;
    repo-blocked-*)       LARAVEL="";     DBT="postgres"; MODE="fail"; REPO_BRANCH="${CASE#repo-blocked-}"; FAIL_TEXT="Composer refused to install the requested versions because they are affected by security advisories" ;;
    laravel99-fails)      LARAVEL="99.0"; DBT="postgres"; MODE="fail"; FAIL_TEXT="Failed to install Laravel" ;;
    *) ;;
esac

# This is a password, including SQL-looking text; it must never execute another statement.
DB_LITERAL_PASSWORD=$'SQLzip_1\'; CREATE ROLE sqlzip_injected; -- "\\ #${NOT_EXPANDED}'
if [ -n "$NATIVE" ] || [ "$CASE" = laravel12-postgres ]; then
    EXTRA+=("--db-$DBT-password" "$DB_LITERAL_PASSWORD")
fi
if [ "$CASE" = laravel13-mysql ]; then
    EXTRA+=(--db-mysql-password 'SQLzip_1 #${NOT_EXPANDED}; literal')
fi
if [ "$CASE" = laravel12-postgres ]; then
    EXTRA+=(--db-postgres-user Sqlzip-user --db-postgres-name Sqlzip-db)
fi

FIL_EMAIL="admin@example.test"
SLUG="mx$(printf '%s' "${CASE}" | tr -cd 'a-z0-9' | cut -c1-16)"
DOMAIN="${SLUG}.example.test"
PROJECT="/var/www/${SLUG}"
for a in "${EXTRA[@]}"; do [ "${a}" = "filament" ] && WITH_FILAMENT=1; done
WITH_FILAMENT="${WITH_FILAMENT:-0}"

dc() { docker compose --project-directory "${PROJECT}" -f "${PROJECT}/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }
serve() { docker exec -d -w /var/www/html "${SLUG}_php" php artisan serve --host=127.0.0.1 --port=8000 --no-reload; }
code() { docker exec "${SLUG}_php" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8000$1"; }
http_is() { [ "$(code "$1")" = "$2" ]; }
expected_major() {
    if [ -n "${LARAVEL}" ]; then printf '%s' "${LARAVEL%%.*}"; else env_val "${REPO_ROOT}/versions.env" LARAVEL_VERSION | cut -d. -f1; fi
}

setup_file() {
    [ -n "${CASE}" ] || skip "set INSTALL_CASE to one of the cases listed at the top of this file"
    [ "${E2E_ALLOW:-}" = "1" ] || skip "the install matrix writes to /var/www and takes ports 80/443: run with E2E_ALLOW=1 in a disposable environment"
    [ "$(id -u)" -eq 0 ] || skip "root is required"
    if [ -n "${NATIVE}" ]; then
        # The DBMS daemons must not inherit bats' file descriptors (3 and 4 are bats' own): otherwise bats
        # waits for them to exit at the end of the run and hangs.
        bash "${REPO_ROOT}/tests/native-db.sh" "${NATIVE}" >"${BATS_FILE_TMPDIR}/native-db.log" 2>&1 3>&- 4>&- </dev/null             || { cat "${BATS_FILE_TMPDIR}/native-db.log" >&2; return 1; }
    fi

    local args=(--slug "${SLUG}" --domain "${DOMAIN}" --db-type "${DBT}" --no-ssl)
    [ -n "${LARAVEL}" ] && args+=(--laravel-version "${LARAVEL}")
    if [ -n "${REPO_BRANCH}" ]; then
        git clone --quiet --branch "${REPO_BRANCH}" --single-branch https://github.com/laravel/laravel.git "${BATS_FILE_TMPDIR}/app"
        args+=(--repo "file://${BATS_FILE_TMPDIR}/app" --branch "${REPO_BRANCH}")
    fi
    if [ "${WITH_FILAMENT}" = "1" ]; then args+=(--filament-email "${FIL_EMAIL}" --filament-password Passw0rd_123); fi
    args+=("${EXTRA[@]}")

    export DEPLOY_LOG="${BATS_FILE_TMPDIR}/deploy.log"
    set +e
    bash "${DEPLOY}" "${args[@]}" >"${DEPLOY_LOG}" 2>&1
    echo "$?" >"${BATS_FILE_TMPDIR}/deploy.exit"
    set -e
}

teardown_file() {
    if [ -f "$BATS_FILE_TMPDIR/orphan-proxy-id" ]; then
        docker rm -f "$(cat "$BATS_FILE_TMPDIR/orphan-proxy-id")" >/dev/null 2>&1 || true
    fi
    if [ -d "${PROJECT}" ]; then
        (cd "${PROJECT}" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
        rm -rf "${PROJECT}"
    fi
    rm -f "/var/www/nginxproxy/sites/${SLUG}.conf" "/var/www/nginxproxy/sites/${SLUG}.conf.disabled"
    if [ -f "${BATS_FILE_TMPDIR}/deploy.log" ] && [ -n "${E2E_KEEP_LOG:-}" ]; then
        cp "${BATS_FILE_TMPDIR}/deploy.log" "${E2E_KEEP_LOG}" || true
    fi
}

# ---------- the deployment itself ----------

@test "${CASE}: the script ends as expected" {
    local exit_code; exit_code="$(cat "${BATS_FILE_TMPDIR}/deploy.exit")"
    if [ "${MODE}" = "ok" ]; then
        [ "${exit_code}" = "0" ] || { echo "deploy-laravel.sh exited with code ${exit_code}; last lines of its output:" >&2; tail -n 60 "${DEPLOY_LOG}" | strip_ansi >&2; return 1; }
        strip_ansi <"${DEPLOY_LOG}" | grep -q "Deployment completed"
        if strip_ansi <"${DEPLOY_LOG}" | grep -qE '^\[ERROR\]'; then return 1; fi
    else
        [ "${exit_code}" != "0" ] || { echo "the script succeeded but was expected to fail" >&2; return 1; }
        strip_ansi <"${DEPLOY_LOG}" | grep -q "${FAIL_TEXT}" || { tail -n 30 "${DEPLOY_LOG}" | strip_ansi >&2; return 1; }
        # a refusal by Composer's security blocking is explained, not just reported
        if [[ "${FAIL_TEXT}" == *"security advisories"* ]]; then
            strip_ansi <"${DEPLOY_LOG}" | grep -q "not a fault of this script" || return 1
        fi
        if strip_ansi <"${DEPLOY_LOG}" | grep -q "Deployment completed"; then return 1; fi
    fi
}

@test "${CASE}: a failed deployment can be cleaned up with remove.sh" {
    [ "${MODE}" = "fail" ] || skip "only for the cases that fail"
    # Even a stopped orphan may own unknown routes; missing files cannot prove otherwise.
    if [ ! -e /var/www/nginxproxy ] && ! docker container inspect nginxproxy >/dev/null 2>&1; then
        docker create --name nginxproxy nginx:1.29.1-alpine > "$BATS_FILE_TMPDIR/orphan-proxy-id" || return 1
        run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}'"
        [ "$status" = 1 ]; [[ "$output" == *"Shared proxy container exists without its configuration"* ]]
        [ -d "$PROJECT" ]; [ -n "$(docker ps -aq --filter "name=${SLUG}_")" ]
        docker rm "$(cat "$BATS_FILE_TMPDIR/orphan-proxy-id")" >/dev/null
        rm "$BATS_FILE_TMPDIR/orphan-proxy-id"
    fi
    run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}'"
    [ "${status}" -eq 0 ]
    [ ! -d "${PROJECT}" ]
    [ -z "$(docker ps -aq --filter "name=${SLUG}_")" ]
}

# ---------- a working application ----------

@test "${CASE}: containers are running (a container database only for a non-native case)" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    for c in php nginx redis cron; do
        container_up "${SLUG}_${c}" || { echo "${SLUG}_${c} is not running" >&2; return 1; }
    done
    if [ -n "${NATIVE}" ]; then
        [ -z "$(docker ps -aq --filter "name=${SLUG}_db")" ]
    else
        container_up "${SLUG}_db"
    fi
}

@test "${CASE}: the requested Laravel version is installed" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    run art --version
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Laravel Framework $(expected_major)."* ]] || { echo "${output}" >&2; return 1; }
}

@test "${CASE}: .env has an application key and the right database settings" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    local f="${PROJECT}/public_html/.env" drv=pgsql host="${SLUG}_db"
    [ "${DBT}" = "mysql" ] && drv=mysql
    # the Docker host as a container sees it: the gateway of the default bridge network
    [ -n "${NATIVE}" ] && host="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
    [ -n "$(env_val "$f" APP_KEY)" ]
    [ "$(env_val "$f" DB_CONNECTION)" = "${drv}" ]
    [ "$(env_val "$f" DB_HOST)" = "${host}" ]
    [ "$(env_val "$f" APP_URL)" = "http://${DOMAIN}" ]
}

@test "${CASE}: migrations ran on the chosen database" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    run art migrate:status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"create_users_table"*"Ran"* ]] || { echo "${output}" >&2; return 1; }
    run art tinker --execute='echo DB::connection()->getDriverName();'
    if [ "${DBT}" = "postgres" ]; then [[ "${output}" == *pgsql* ]]; else [[ "${output}" == *mysql* ]]; fi
}

@test "${CASE}: the framework boots (about, route:list)" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    run art about
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
    run art route:list
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
}

@test "${CASE}: the welcome page answers and storage is writable" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    serve
    eventually 30 http_is / 200
    docker exec "${SLUG}_php" test -w /var/www/html/storage/logs
    docker exec "${SLUG}_php" test -w /var/www/html/bootstrap/cache
    run art tinker --execute='Cache::put("mx-key", "mx-value", 60); echo Cache::get("mx-key");'
    [[ "${output}" == *"mx-value"* ]]
}

@test "${CASE}: Filament login page and administrator" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    [ "${WITH_FILAMENT}" = "1" ] || skip "Filament was not requested"
    eventually 30 http_is /admin/login 200
    run art tinker --execute="echo App\\Models\\User::where('email','${FIL_EMAIL}')->exists() ? 'ADMIN_OK' : 'NO_ADMIN';"
    [[ "${output}" == *ADMIN_OK* ]]
}

@test "${CASE}: native SQL treats the password literally and repeat creation keeps it" {
    [ -n "$NATIVE" ] || skip "only for native databases"
    local dbname dbuser
    dbname=$(env_val "$PROJECT/.env" "DB_${NATIVE^^}_NAME")
    dbuser=$(env_val "$PROJECT/.env" "DB_${NATIVE^^}_USER")
    if [ "$NATIVE" = postgres ]; then
        [ -z "$(sudo -u postgres psql -X -Atc "SELECT 1 FROM pg_roles WHERE rolname='sqlzip_injected'")" ]
    else
        [ -z "$(mysql -u root -pRoot_e2e_1 -Nse "SELECT 1 FROM mysql.user WHERE User='sqlzip_injected'")" ]
    fi
    run bash -c '
        source "$1"
        DB_TYPE="$2"; DB_NATIVE=true; DB_ROOT_PASSWORD=Root_e2e_1
        DB_POSTGRES_NAME="$3"; DB_POSTGRES_USER="$4"; DB_POSTGRES_PASSWORD=Unused_Replacement_1
        DB_MYSQL_NAME="$3"; DB_MYSQL_USER="$4"; DB_MYSQL_PASSWORD=Unused_Replacement_1
        create_native_database
    ' _ "$DEPLOY" "$NATIVE" "$dbname" "$dbuser"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    run dc run --rm -T -e "SQLZIP_EXPECTED=$DB_LITERAL_PASSWORD" artisan tinker \
        --execute='echo config("database.connections.".config("database.default").".password") === getenv("SQLZIP_EXPECTED") ? "PASSWORD_OK" : "PASSWORD_CHANGED"; DB::connection()->getPdo();'
    [ "$status" -eq 0 ]
    [[ "$output" == *PASSWORD_OK* ]]
    [[ "$output" != *PASSWORD_CHANGED* ]]
}

@test "${CASE}: containerized PostgreSQL quotes its initialization password and identifiers" {
    [ "$CASE" = laravel12-postgres ] || skip "only for the PostgreSQL initialization fixture"
    [ -z "$(docker exec "${SLUG}_db" psql -X -U Sqlzip-user -d Sqlzip-db -Atc "SELECT 1 FROM pg_roles WHERE rolname='sqlzip_injected'")" ]
    run dc run --rm -T -e "SQLZIP_EXPECTED=$DB_LITERAL_PASSWORD" artisan tinker \
        --execute='echo config("database.connections.".config("database.default").".password") === getenv("SQLZIP_EXPECTED") ? "PASSWORD_OK" : "PASSWORD_CHANGED"; DB::connection()->getPdo();'
    [ "$status" -eq 0 ]
    [[ "$output" == *PASSWORD_OK* ]]
    [[ "$output" != *PASSWORD_CHANGED* ]]
}

@test "${CASE}: PostgreSQL DDL failure aborts without claiming the user already exists" {
    [ "$NATIVE" = postgres ] || skip "only for native PostgreSQL"
    run bash -c '
        source "$1"
        DB_TYPE=postgres; DB_NATIVE=true
        DB_POSTGRES_NAME=sqlzip_error; DB_POSTGRES_USER=pg_sqlzip_forbidden; DB_POSTGRES_PASSWORD=Test_1
        create_native_database
    ' _ "$DEPLOY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to create native PostgreSQL"* ]]
    [[ "$output" != *"already exists"* ]]
    [ -z "$(sudo -u postgres psql -X -Atc "SELECT 1 FROM pg_database WHERE datname='sqlzip_error'")" ]
}

# ---------- removal ----------

@test "${CASE}: Laravel keeps reserved dotenv words and literal quotes as credential strings" {
    [ "$CASE" = laravel12-postgres ] || skip "one real PHP/dotenv process is enough for this encoding"
    run bash -c '
        source "$1"
        for value in true FALSE null EMPTY "(true)" "(false)" "(null)" "(empty)" "\"literal\"" "\""; do
            encoded=$(db_env_value "$value" laravel)
            docker exec -w /var/www/html -e "SQLZIP_VALUE=$value" -e "SQLZIP_ENV=SQLZIP_CHECK=$encoded" "$2" php -r '\''
                require "vendor/autoload.php";
                $parsed = Dotenv\Dotenv::parse(getenv("SQLZIP_ENV"));
                $_ENV["SQLZIP_CHECK"] = $parsed["SQLZIP_CHECK"];
                $actual = Illuminate\Support\Env::get("SQLZIP_CHECK");
                if (!is_string($actual) || $actual !== getenv("SQLZIP_VALUE")) { exit(1); }
            '\'' || exit 1
        done
        value=$(printf "\047literal\047")
        encoded=$(db_env_value "$value" laravel)
        docker exec -w /var/www/html -e "SQLZIP_VALUE=$value" -e "SQLZIP_ENV=SQLZIP_CHECK=$encoded" "$2" php -r '\''
            require "vendor/autoload.php";
            $_ENV["SQLZIP_CHECK"] = Dotenv\Dotenv::parse(getenv("SQLZIP_ENV"))["SQLZIP_CHECK"];
            $actual = Illuminate\Support\Env::get("SQLZIP_CHECK");
            if (!is_string($actual) || $actual !== getenv("SQLZIP_VALUE")) { exit(1); }
        '\''
    ' _ "$DEPLOY" "${SLUG}_php"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "${CASE}: remove.sh cleans up the project (and a native database)" {
    [ "${MODE}" = "ok" ] || skip "no application in this case"
    local dbname
    dbname="$(env_val "${PROJECT}/.env" DB_POSTGRES_NAME)"
    [ "${DBT}" = "mysql" ] && dbname="$(env_val "${PROJECT}/.env" DB_MYSQL_NAME)"
    local extra=()
    [ "${NATIVE}" = "mysql" ] && extra=(--db-root-password Root_e2e_1)
    run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}' ${extra[*]:-}"
    [ "${status}" -eq 0 ] || { printf '%s\n' "${output}" >&2; return 1; }
    [ ! -d "${PROJECT}" ]
    [ -z "$(docker ps -aq --filter "name=${SLUG}_")" ]
    if [ "${NATIVE}" = "postgres" ]; then
        [ -z "$(sudo -u postgres psql -Atc "select 1 from pg_database where datname='${dbname}'")" ]
    elif [ "${NATIVE}" = "mysql" ]; then
        [ -z "$(mysql -u root -pRoot_e2e_1 -Nse "show databases like '${dbname}'")" ]
    fi
}
