#!/usr/bin/env bats
# End-to-end for modules: deploy-laravel.sh --with filament,horizon.
#
# horizon requires redis, so the run also checks the automatic dependency, the compose service that
# the module adds after Laravel is installed, and that Horizon really processes a queued job.
#
# The backup module is part of the deployment: its dumps and restore are checked as well.
#
# WARNING: like e2e.bats this writes to /var/www, takes ports 80/443 and creates Docker
# resources. Run it only in a disposable environment and only with E2E_ALLOW=1. The tests run
# in order and depend on each other.

load helpers

E2E_DB="${E2E_DB:-postgres}"
SLUG="e2emods"
DOMAIN="${SLUG}.example.test"
PROJECT="/var/www/${SLUG}"
PORT_HTTP=18080 PORT_HTTPS=18443 PORT_PHP=19000 PORT_REDIS=16379 PORT_DB=15432
DB_NAME="e2emodsdb" DB_USER="e2emuser" DB_PASS="Dbpass_123" REDIS_PASS="Rpass_123"
FIL_EMAIL="admin@example.test" FIL_NAME="ModAdmin" FIL_PASS="Passw0rd_123"

dc() { docker compose --project-directory "${PROJECT}" -f "${PROJECT}/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }
serve() { docker exec -d -w /var/www/html "${SLUG}_php" php artisan serve --host=127.0.0.1 --port=8000 --no-reload; }
code() { docker exec "${SLUG}_php" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8000$1"; }
http_is() { [ "$(code "$1")" = "$2" ]; }

# ---------- setup ----------

setup_file() {
    [ "${E2E_ALLOW:-}" = "1" ] || skip "e2e writes to /var/www and takes ports 80/443: run with E2E_ALLOW=1 in a disposable environment"
    [ "$(id -u)" -eq 0 ] || skip "root is required"

    # A removed installation can leave this image tag behind. Seed the other engine
    # to ensure module startup rebuilds from the currently selected DB_IMAGE.
    local stale_image
    if [ "$E2E_DB" = postgres ]; then stale_image=$(env_val "$REPO_ROOT/versions.env" MYSQL_IMAGE)
    else stale_image=$(env_val "$REPO_ROOT/versions.env" POSTGRES_IMAGE); fi
    printf 'FROM %s\n' "$stale_image" | docker build -q -t "${SLUG}-backup" - \
        > "$BATS_FILE_TMPDIR/stale-image.log" 2>&1 || { cat "$BATS_FILE_TMPDIR/stale-image.log"; return 1; }

    local db_args=("--port-$E2E_DB" "$PORT_DB" "--db-$E2E_DB-name" "$DB_NAME"
        "--db-$E2E_DB-user" "$DB_USER" "--db-$E2E_DB-password" "$DB_PASS")
    if [ "$E2E_DB" = mysql ]; then db_args+=(--db-mysql-root-password "Root_$DB_PASS"); fi
    export DEPLOY_LOG="${BATS_FILE_TMPDIR}/deploy.log"
    set +e
    bash "${DEPLOY}" \
        --slug "${SLUG}" --domain "${DOMAIN}" --db-type "$E2E_DB" --no-ssl --laravel-version 12.0 \
        --port-http "${PORT_HTTP}" --port-https "${PORT_HTTPS}" --port-php "${PORT_PHP}" \
        --port-redis "${PORT_REDIS}" --redis-password "${REDIS_PASS}" "${db_args[@]}" \
        --with filament,horizon,backup \
        --filament-email "${FIL_EMAIL}" --filament-name "${FIL_NAME}" --filament-password "${FIL_PASS}" \
        >"${DEPLOY_LOG}" 2>&1
    echo "$?" >"${BATS_FILE_TMPDIR}/deploy.exit"
    set -e
}

teardown_file() {
    if [ -d "${PROJECT}" ]; then
        (cd "${PROJECT}" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
        rm -rf "${PROJECT}"
    fi
    rm -f "/var/www/nginxproxy/sites/${SLUG}.conf" "/var/www/nginxproxy/sites/${SLUG}.conf.disabled"
    if [ -f "${BATS_FILE_TMPDIR}/deploy.log" ] && [ -n "${E2E_KEEP_LOG:-}" ]; then
        cp "${BATS_FILE_TMPDIR}/deploy.log" "${E2E_KEEP_LOG}" || true
    fi
}

# ---------- the deployment ----------

@test "modules: the script exited with code 0 and printed the summary" {
    [ "$(cat "${BATS_FILE_TMPDIR}/deploy.exit")" = "0" ] || {
        tail -n 40 "${DEPLOY_LOG}" | strip_ansi >&2
        return 1
    }
    strip_ansi <"${DEPLOY_LOG}" | grep -q "Deployment completed"
    if strip_ansi <"${DEPLOY_LOG}" | grep -qE '^\[ERROR\]'; then return 1; fi
}

@test "modules: horizon enabled redis by itself" {
    strip_ansi <"${DEPLOY_LOG}" | grep -q "Module horizon requires redis: enabling it"
    local f="${PROJECT}/public_html/.env"
    [ "$(env_val "$f" REDIS_HOST)" = "${SLUG}_redis" ]
    [ "$(env_val "$f" REDIS_PASSWORD)" = "${REDIS_PASS}" ]
    [ "$(env_val "$f" QUEUE_CONNECTION)" = "redis" ]
}

@test "modules: project containers and the horizon service are running, there is no queue worker" {
    for c in php nginx redis cron db horizon backup; do
        container_up "${SLUG}_${c}" || { echo "${SLUG}_${c} is not running" >&2; return 1; }
    done
    [ -z "$(docker ps -aq --filter "name=${SLUG}_queue")" ]
}

@test "modules: the service was added to docker-compose.yml and the file is still valid" {
    grep -q "container_name: ${SLUG}_horizon" "${PROJECT}/docker-compose.yml"
    if grep -q '{SLUG}' "${PROJECT}/docker-compose.yml"; then return 1; fi
    run dc config --quiet
    [ "${status}" -eq 0 ]
    # the section order is intact: the service sits before the top-level networks
    [ "$(grep -n "^  horizon:" "${PROJECT}/docker-compose.yml" | cut -d: -f1)" -lt "$(grep -n '^networks:' "${PROJECT}/docker-compose.yml" | cut -d: -f1)" ]
}

@test "modules: Filament admin user, password and login page" {
    grep -qF "\"filament/filament\": \"$(env_val "${REPO_ROOT}/versions.env" FILAMENT_VERSION)\"" "${PROJECT}/public_html/composer.json"
    [ "$(compose_env_val "${PROJECT}/.env" FILAMENT_ADMIN_EMAIL)" = "${FIL_EMAIL}" ]
    run art tinker --execute="\$u = App\\Models\\User::where('email','${FIL_EMAIL}')->first(); echo \$u ? \$u->name.'|'.(Hash::check('${FIL_PASS}', \$u->password) ? 'PASS_OK' : 'PASS_BAD') : 'NO_USER';"
    [[ "${output}" == *"${FIL_NAME}|PASS_OK"* ]]
    serve
    eventually 30 http_is /admin/login 200
}

@test "modules: laravel/horizon is installed and Horizon is running" {
    grep -q '"laravel/horizon"' "${PROJECT}/public_html/composer.json"
    horizon_running() { art horizon:status 2>&1 | grep -qi "running"; }
    eventually 90 horizon_running
}

@test "modules: the production Horizon dashboard denies unauthenticated access" {
    http_is /horizon 403
}

@test "modules: production Filament access is limited to the provisioned administrator" {
    run art tinker --execute='echo app()->environment()."|".(config("app.debug") ? "DEBUG" : "NO_DEBUG"); $panel = Filament\Facades\Filament::getPanel("admin"); $admin = App\Models\User::where("email", config("laraship.filament_admin_email"))->firstOrFail(); $other = App\Models\User::factory()->make(["email" => "other@example.test"]); echo "|".($admin->canAccessPanel($panel) ? "ADMIN_ALLOWED" : "ADMIN_DENIED")."|".($other->canAccessPanel($panel) ? "OTHER_ALLOWED" : "OTHER_DENIED");'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"production|NO_DEBUG|ADMIN_ALLOWED|OTHER_DENIED"* ]]
}

@test "modules: safe defaults protect secrets and ports without --bind-local" {
    [ "$(stat -c %a "${PROJECT}/.env")" = 600 ]
    [ "$(stat -c %a "${PROJECT}/public_html/.env")" = 600 ]
    docker port "${SLUG}_nginx" 80 | grep -q "^127.0.0.1:${PORT_HTTP}$"
    docker port "${SLUG}_redis" 6379 | grep -q "^127.0.0.1:${PORT_REDIS}$"
    local port=5432; if [ "$E2E_DB" = mysql ]; then port=3306; fi
    docker port "${SLUG}_db" "$port" | grep -q "^127.0.0.1:${PORT_DB}$"
}

@test "modules: Horizon processes a queued job" {
    art tinker --execute='Cache::put("e2e-flag", "1", 600); Artisan::queue("cache:forget", ["key" => "e2e-flag"]);'
    flag_gone() { [ "$(art tinker --execute='echo Cache::has("e2e-flag") ? "yes" : "no";' | tail -n1)" = "no" ]; }
    eventually 90 flag_gone
}

# ---------- backup module ----------

backup_ext() { if [ "$E2E_DB" = "mysql" ]; then echo "sql.gz"; else echo "dump"; fi; }
backup_files() { ls -1 "${PROJECT}/backups/" 2>/dev/null | grep -E "^${SLUG}-.*\.$(backup_ext)$" || true; }
newest_dump() { ls -1t "${PROJECT}/backups/" | grep -E "^${SLUG}-.*\.$(backup_ext)$" | head -n1; }
have_dump() { [ -n "$(backup_files)" ]; }
marker_count() { art tinker --execute='echo Schema::hasTable("e2e_marker") ? DB::table("e2e_marker")->count() : "none";' | tail -n1; }

@test "backup: the service runs, made the first dump, and the dump is valid" {
    container_up "${SLUG}_backup"
    local client=pg_dump; if [ "$E2E_DB" = mysql ]; then client=mysqldump; fi
    run docker exec "${SLUG}_backup" "$client" --version
    [ "$status" = 0 ] || {
        echo "$output"
        docker inspect --format '{{.Image}} {{.Config.Image}}' "${SLUG}_backup"
        docker logs --tail 8 "${SLUG}_backup"
        return 1
    }
    eventually 90 have_dump
    local f; f="$(newest_dump)"
    [ -s "${PROJECT}/backups/${f}" ]
    if [ "$E2E_DB" = "mysql" ]; then
        docker exec "${SLUG}_backup" sh -c "gzip -dc /backups/${f} | grep -q 'CREATE TABLE .users.'"
    else
        docker exec "${SLUG}_backup" pg_restore -l "/backups/${f}" | grep -q ' users'
    fi
}

@test "backup.sh now takes a dump and list shows it" {
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
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" restore "../etc/passwd" --yes
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Invalid dump file name"* ]]
    run bash "${REPO_ROOT}/backup.sh" --slug "${SLUG}" restore "${SLUG}-20000101-000000.$(backup_ext)" --yes
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"No such dump"* ]]
}

# ---------- lifecycle ----------


@test "TERM during restore stops its import container, restarts services and preserves maintenance" {
    local dump script="$PROJECT/.config/backup/restore.sh" pid result=0
    sleep 2
    run bash "$REPO_ROOT/backup.sh" --slug "$SLUG" now
    [ "$status" = 0 ]; dump=$(newest_dump)
    cp "$script" "$BATS_TEST_TMPDIR/restore-original"
    { printf '#!/bin/sh\ntouch /backups/e2e-cancel-started\nsleep 60\n'; cat "$BATS_TEST_TMPDIR/restore-original"; } > "$script"
    bash "$REPO_ROOT/backup.sh" --slug "$SLUG" restore "$dump" --yes > "$BATS_TEST_TMPDIR/cancel-restore.log" 2>&1 & pid=$!
    eventually 60 test -f "$PROJECT/backups/e2e-cancel-started"
    kill -TERM "$pid"
    wait "$pid" || result=$?
    cat "$BATS_TEST_TMPDIR/restore-original" > "$script"
    [ "$result" != 0 ]
    [ -z "$(docker ps -aq --filter "name=^${SLUG}_restore_import$")" ]
    [ -f "$PROJECT/public_html/storage/framework/down" ]
    eventually 30 container_up "${SLUG}_php"
    eventually 30 container_up "${SLUG}_horizon"
    grep -q 'maintenance remains enabled' "$BATS_TEST_TMPDIR/cancel-restore.log"
    art up
    rm -f "$PROJECT/backups/e2e-cancel-started"
}


@test "modules: deactivate stops the horizon and backup services, activate brings them back" {
    run bash "${REPO_ROOT}/deactivate.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    if container_up "${SLUG}_horizon"; then return 1; fi
    run bash "${REPO_ROOT}/activate.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    eventually 60 container_up "${SLUG}_horizon"
    eventually 60 container_up "${SLUG}_backup"
}

@test "modules: remove cleans up the project" {
    run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}'"
    [ "${status}" -eq 0 ]
    [ ! -d "${PROJECT}" ]
    [ -z "$(docker ps -aq --filter "name=${SLUG}_")" ]
}
