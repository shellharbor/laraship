#!/usr/bin/env bats
# End-to-end for deploying an existing application: deploy-laravel.sh --repo, then update.sh.
#
# The "application" is a clone of laravel/laravel (branch 12.x) used through file:// so that new
# commits can be created locally. Needs network access (GitHub, Packagist, Docker Hub).
#
# WARNING: like e2e.bats this writes to /var/www, takes ports 80/443 and creates Docker
# resources. Run it only in a disposable environment and only with E2E_ALLOW=1. The tests run
# in order and depend on each other.
#
# E2E_BRANCH picks the branch of laravel/laravel (default 12.x), so the same checks run against
# other Laravel versions (the install matrix does that for 10.x, 11.x and 13.x).
#
# SSH cloning with --deploy-key has a separate loopback server fixture in e2e-options.bats.
# Argument validation is covered by validation.bats.

load helpers

E2E_DB="${E2E_DB:-postgres}"
SLUG="e2erepo"
DOMAIN="${SLUG}.example.test"
PROJECT="/var/www/${SLUG}"
BRANCH="${E2E_BRANCH:-12.x}"     # a laravel/laravel branch: 10.x, 11.x, 12.x, 13.x
PORT_HTTP=18080 PORT_HTTPS=18443 PORT_PHP=19000 PORT_REDIS=16379 PORT_DB=15432
DB_NAME="e2erepodb" DB_USER="e2eruser" DB_PASS="Dbpass_123" REDIS_PASS="Rpass_123"

dc() { docker compose --project-directory "${PROJECT}" -f "${PROJECT}/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }
app_git() { git -C "${PROJECT}/public_html" -c safe.directory="${PROJECT}/public_html" "$@"; }
up_git() { git -C "${UPSTREAM}" -c user.name=e2e -c user.email=e2e@example.test "$@"; }

serve() {
    docker exec -d -w /var/www/html "${SLUG}_php" php artisan serve --host=127.0.0.1 --port=8000 --no-reload
}
code() { docker exec "${SLUG}_php" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8000$1"; }
http_is() { [ "$(code "$1")" = "$2" ]; }

# ---------- setup ----------

setup_file() {
    [ "${E2E_ALLOW:-}" = "1" ] || skip "e2e writes to /var/www and takes ports 80/443: run with E2E_ALLOW=1 in a disposable environment"
    [ "$(id -u)" -eq 0 ] || skip "root is required"

    local db_args=("--port-$E2E_DB" "$PORT_DB" "--db-$E2E_DB-name" "$DB_NAME"
        "--db-$E2E_DB-user" "$DB_USER" "--db-$E2E_DB-password" "$DB_PASS")
    if [ "$E2E_DB" = mysql ]; then db_args+=(--db-mysql-root-password "Root_$DB_PASS"); fi
    export UPSTREAM="${BATS_FILE_TMPDIR}/app"
    git clone --quiet --branch "${BRANCH}" --single-branch https://github.com/laravel/laravel.git "${UPSTREAM}"
    export DEPLOY_LOG="${BATS_FILE_TMPDIR}/deploy.log"

    set +e
    bash "${DEPLOY}" \
        --slug "${SLUG}" --domain "${DOMAIN}" --db-type "$E2E_DB" --no-ssl \
        --port-http "${PORT_HTTP}" --port-https "${PORT_HTTPS}" --port-php "${PORT_PHP}" \
        --port-redis "${PORT_REDIS}" --redis-password "${REDIS_PASS}" "${db_args[@]}" \
        --repo "file://${UPSTREAM}" --branch "${BRANCH}" \
        --post-deploy 'touch storage/app/e2e-post-deploy' \
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

# ---------- --repo ----------

@test "--repo: the script exited with code 0 and printed the summary" {
    [ "$(cat "${BATS_FILE_TMPDIR}/deploy.exit")" = "0" ] || {
        tail -n 40 "${DEPLOY_LOG}" | strip_ansi >&2
        return 1
    }
    strip_ansi <"${DEPLOY_LOG}" | grep -q "Deployment completed"
    if strip_ansi <"${DEPLOY_LOG}" | grep -qE '^\[ERROR\]'; then return 1; fi
}

@test "--repo: project containers are running" {
    for c in php nginx redis cron db; do
        container_up "${SLUG}_${c}" || { echo "${SLUG}_${c} is not running" >&2; return 1; }
    done
}

@test "--repo: public_html is the repository at the requested branch" {
    [ "$(app_git rev-parse HEAD)" = "$(up_git rev-parse HEAD)" ]
    [ "$(app_git rev-parse --abbrev-ref HEAD)" = "${BRANCH}" ]
    [ -f "${PROJECT}/public_html/artisan" ]
}

@test "--repo: .deploy-meta records the source (mode 600, no key, no credentials)" {
    local f="${PROJECT}/.deploy-meta"
    [ "$(stat -c '%a' "${f}")" = "600" ]
    [ "$(env_val "${f}" REPO_URL)" = "file://${UPSTREAM}" ]
    [ "$(env_val "${f}" REPO_BRANCH)" = "${BRANCH}" ]
    [ -z "$(env_val "${f}" DEPLOY_KEY_FILE)" ]
    [ "$(env_val "${f}" POST_DEPLOY)" = "touch storage/app/e2e-post-deploy" ]
}

@test "--repo: production dependencies only (composer install --no-dev)" {
    [ -f "${PROJECT}/public_html/vendor/autoload.php" ]
    [ ! -d "${PROJECT}/public_html/vendor/phpunit" ]
}

@test "--repo: .env comes from .env.example, APP_KEY is generated, DB settings are written" {
    local f="${PROJECT}/public_html/.env"
    [ "$(env_val "$f" APP_ENV)" = production ]
    [ "$(env_val "$f" APP_DEBUG)" = false ]
    [ "$(stat -c %a "$f")" = 600 ]
    [ "$(stat -c %a "${PROJECT}/.env")" = 600 ]
    [ -n "$(env_val "$f" APP_KEY)" ]
    local connection=pgsql; if [ "$E2E_DB" = mysql ]; then connection=mysql; fi
    [ "$(env_val "$f" DB_CONNECTION)" = "$connection" ]
    [ "$(env_val "$f" DB_HOST)" = "${SLUG}_db" ]
    [ "$(env_val "$f" DB_DATABASE)" = "${DB_NAME}" ]
    [ "$(env_val "$f" DB_USERNAME)" = "${DB_USER}" ]
    [ "$(env_val "$f" DB_PASSWORD)" = "${DB_PASS}" ]
    [ "$(env_val "$f" APP_URL)" = "http://${DOMAIN}" ]
}

@test "--repo: migrations ran and the application answers" {
    run art migrate:status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"create_users_table"*"Ran"* ]]
    serve
    eventually 30 http_is / 200
}

@test "--repo: the installed framework is the one of the branch" {
    run art --version
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Laravel Framework ${BRANCH%%.*}."* ]] || { echo "${output}" >&2; return 1; }
}

@test "--post-deploy: the commands ran in the php container" {
    docker exec "${SLUG}_php" test -f /var/www/html/storage/app/e2e-post-deploy
}

# ---------- update.sh ----------

@test "update.sh: nothing to do when the branch has no new commits" {
    run bash "${REPO_ROOT}/update.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Already up to date"* ]]
}

@test "update.sh: pulls a new commit, runs the migration and serves the new code" {
    mkdir -p "${UPSTREAM}/database/migrations"
    cat >"${UPSTREAM}/database/migrations/2099_01_01_000000_create_e2e_things_table.php" <<'PHP'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('e2e_things', function (Blueprint $table) {
            $table->id();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('e2e_things');
    }
};
PHP
    printf "\nRoute::get('/e2e-version', fn () => 'v2');\n" >>"${UPSTREAM}/routes/web.php"
    up_git add -A
    up_git commit --quiet -m "e2e: add a table and a route"

    run bash "${REPO_ROOT}/update.sh" --slug "${SLUG}"
    [ "${status}" -eq 0 ] || { printf '%s\n' "${output}" | strip_ansi >&2; return 1; }

    [ "$(app_git rev-parse HEAD)" = "$(up_git rev-parse HEAD)" ]
    run art tinker --execute='echo Schema::hasTable("e2e_things") ? "table-yes" : "table-no";'
    [[ "${output}" == *"table-yes"* ]]
    # The application is back from maintenance mode and serves the new route
    [ ! -f "${PROJECT}/public_html/storage/framework/down" ]
    serve
    eventually 30 http_is /e2e-version 200
    run docker exec "${SLUG}_php" curl -s "http://127.0.0.1:8000/e2e-version"
    [ "${output}" = "v2" ]
}

@test "update.sh: refuses to run over uncommitted local changes" {
    echo "// local edit" >>"${PROJECT}/public_html/routes/web.php"
    run bash "${REPO_ROOT}/update.sh" --slug "${SLUG}" --force
    [ "${status}" -ne 0 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"uncommitted changes to tracked files"* ]]
    app_git checkout -- routes/web.php
    # Root's checkout can create mode-600 files under the full runner's private umask.
    dc run --rm permissions
}

@test "update.sh: a failing migration keeps maintenance mode and prints the rollback commands" {
    local before; before="$(up_git rev-parse HEAD)"
    cat >"${UPSTREAM}/database/migrations/2099_01_02_000000_e2e_broken.php" <<'PHP'
<?php

use Illuminate\Database\Migrations\Migration;

return new class extends Migration
{
    public function up(): void
    {
        throw new RuntimeException('e2e broken migration');
    }
};
PHP
    up_git add -A
    up_git commit --quiet -m "e2e: a broken migration"

    run bash "${REPO_ROOT}/update.sh" --slug "${SLUG}"
    [ "${status}" -ne 0 ]
    output="$(printf '%s' "${output}" | strip_ansi)"
    [[ "${output}" == *"Update failed at step: artisan migrate"* ]]
    [[ "${output}" == *"reset --hard ${before}"* ]]
    # Maintenance mode is on so a half-migrated application is not served
    [ -f "${PROJECT}/public_html/storage/framework/down" ]
}

@test "update.sh: the printed rollback restores the previous commit and brings the site back" {
    local before; before="$(up_git rev-parse HEAD~1)"
    app_git reset --hard --quiet "${before}"
    dc run --rm permissions
    run art up
    [ "${status}" -eq 0 ]
    [ "$(app_git rev-parse HEAD)" = "${before}" ]
    [ ! -f "${PROJECT}/public_html/storage/framework/down" ]
}

@test "TERM during a real migration stops its one-off container and preserves maintenance" {
    local before pid result=0
    before=$(app_git rev-parse HEAD)
    up_git rm --quiet database/migrations/2099_01_02_000000_e2e_broken.php
    cat > "$UPSTREAM/database/migrations/2099_01_03_000000_e2e_slow.php" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
return new class extends Migration {
    public function up(): void {
        file_put_contents(storage_path('app/e2e-slow-started'), '1');
        sleep(60);
        file_put_contents(storage_path('app/e2e-slow-finished'), '1');
    }
};
PHP
    up_git add -A; up_git commit --quiet -m "e2e: slow cancellable migration"
    bash "$REPO_ROOT/update.sh" --slug "$SLUG" > "$BATS_TEST_TMPDIR/cancel.log" 2>&1 & pid=$!
    eventually 90 test -f "$PROJECT/public_html/storage/app/e2e-slow-started"
    kill -TERM "$pid"
    wait "$pid" || result=$?
    [ "$result" != 0 ]
    [ -f "$PROJECT/public_html/storage/framework/down" ]
    [ ! -e "$PROJECT/public_html/storage/app/e2e-slow-finished" ]
    [ -z "$(docker ps -aq --filter "name=^${SLUG}_update_artisan$")" ]
    grep -q 'interrupted update' "$BATS_TEST_TMPDIR/cancel.log"
    app_git reset --hard --quiet "$before"
    dc run --rm permissions
    art up
}

@test "no-migrate updates code without executing a pending migration" {
    run bash "$REPO_ROOT/update.sh" --slug "$SLUG" --no-migrate
    [ "$status" = 0 ]
    [ "$(app_git rev-parse HEAD)" = "$(up_git rev-parse HEAD)" ]
    [ ! -e "$PROJECT/public_html/storage/app/e2e-slow-finished" ]
    [ ! -e "$PROJECT/public_html/storage/framework/down" ]
}

@test "remove: cleans up the project" {
    run bash -c "echo yes | bash '${REPO_ROOT}/remove.sh' --slug '${SLUG}' --domain '${DOMAIN}'"
    [ "${status}" -eq 0 ]
    [ ! -d "${PROJECT}" ]
    [ -z "$(docker ps -aq --filter "name=${SLUG}_")" ]
}
