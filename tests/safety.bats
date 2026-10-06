#!/usr/bin/env bats
# P1 regression tests use temporary files, real Git/gzip and fake service commands.
# Compose parsing does not need a daemon; no running application or external server is touched.

load helpers

setup() {
    export SAFETY_WORK="${BATS_TEST_TMPDIR}/safety"
    mkdir -p "${SAFETY_WORK}"
}

@test "container deployment refuses native DB after resolving config and before Docker" {
    require_root
    printf 'DB_NATIVE=true\nDB_TYPE=postgres\nDOMAIN=container.example.test\nSLUG=container-native-refusal\n' > "$SAFETY_WORK/native.conf"
    chmod 600 "$SAFETY_WORK/native.conf"
    run env LARASHIP_CONTAINER=1 bash "$DEPLOY" --config "$SAFETY_WORK/native.conf" --no-ssl
    [ "$status" -eq 1 ]
    [[ "$output" == *"Native database provisioning requires"* ]]
    [ ! -e /var/www/container-native-refusal ]
}

@test "ZIP can be published in an explicitly mounted output directory" {
    require_root
    make_archive_project
    mkdir -p "$SAFETY_WORK/output"
    export LARASHIP_ARCHIVE_DIR="$SAFETY_WORK/output"
    run_archive
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    local archive; archive=$(cat "$SAFETY_WORK/backup-path")
    [[ "$archive" == "$SAFETY_WORK/output/"* ]]
    [ "$(stat -c %a "$archive")" = 600 ]
    unset LARASHIP_ARCHIVE_DIR
}

@test "full launch matrix refuses execution outside the disposable sandbox" {
    run env -u LARASHIP_TEST_SANDBOX bash "$REPO_ROOT/tests/full-matrix.sh"
    [ "$status" = 1 ]; [[ "$output" == *"Full matrix requires the disposable sandbox"* ]]
}

@test "full launch matrix refuses existing public reports and symlink destinations before Docker" {
    [ "$(id -u)" = 0 ] && [ -f /.dockerenv ] || skip "root Docker fixture required"
    mkdir -p "$SAFETY_WORK/reports" "$SAFETY_WORK/bin"
    echo prior > "$SAFETY_WORK/reports/results.tsv"
    chmod 755 "$SAFETY_WORK/reports"; chmod 644 "$SAFETY_WORK/reports/results.tsv"
    printf '#!/bin/sh\ntouch "$SAFETY_WORK/docker-called"\nexit 77\n' > "$SAFETY_WORK/bin/docker"
    chmod +x "$SAFETY_WORK/bin/docker"
    ln -s "$SAFETY_WORK/reports" "$SAFETY_WORK/report-link"
    local directory
    for directory in reports report-link; do
        run env PATH="$SAFETY_WORK/bin:$PATH" LARASHIP_TEST_SANDBOX=1 FULL_SCENARIOS=unknown \
            FULL_RESULTS_DIR="$SAFETY_WORK/$directory" bash "$REPO_ROOT/tests/full-matrix.sh"
        [ "$status" = 1 ]; [[ "$output" == *"empty real directory"* ]]
        [ "$(cat "$SAFETY_WORK/reports/results.tsv")" = prior ]
        [ ! -e "$SAFETY_WORK/docker-called" ]
    done
}

@test "removing an unregistered first deployment needs no proxy configuration" {
    run bash -c '
        source "$1/remove.sh"
        WWW_DIR="$SAFETY_WORK"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$WWW_DIR/locks"
        docker() { [[ "$*" == "ps -aq --filter name=^/nginxproxy$" ]] || return 77; }
        proxy_worker remove_proxy_site
    ' _ "$REPO_ROOT"
    [ "$status" = 0 ]; [[ "$output" == *"No shared proxy configuration to change"* ]]
    [ ! -e "$SAFETY_WORK/nginxproxy" ]
    [ -z "$(find "$SAFETY_WORK" -maxdepth 1 -name '.laraship-proxy.*' -print -quit)" ]
}

@test "missing proxy configuration retains data when a container exists or Docker is unavailable" {
    local mode
    for mode in orphan unavailable; do
        run bash -c '
            source "$1/remove.sh"
            WWW_DIR="$SAFETY_WORK"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$WWW_DIR/locks"
            docker() {
                [[ "$2" != unavailable ]] || return 77
                printf "orphan-container\n"
            }
            if [[ "$2" = unavailable ]]; then docker() { return 77; }; fi
            proxy_worker remove_proxy_site
        ' _ "$REPO_ROOT" "$mode"
        [ "$status" = 1 ]; [[ "$output" == *"Shared proxy container exists"* || "$output" == *"Cannot check whether the shared proxy exists"* ]]
        [ ! -e "$SAFETY_WORK/nginxproxy" ]
    done
}

prepare_migration_guard_fixture() {
    mkdir -p "$SAFETY_WORK/tests" "$SAFETY_WORK/bin"
    sed 's|^MIGRATION_DIR=.*|MIGRATION_DIR="$SAFETY_WORK/migration-fixture"|' "$REPO_ROOT/tests/e2e-db-migration.bats" > "$SAFETY_WORK/tests/migration.bats"
    cp "$REPO_ROOT/tests/helpers.bash" "$SAFETY_WORK/tests/helpers.bash"
    cp "$REPO_ROOT/versions.env" "$SAFETY_WORK/versions.env"
    export FAKE_DOCKER_LOG="$SAFETY_WORK/docker-calls"
    cat > "$SAFETY_WORK/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "${COLLISION_RESOURCE:-}:$*" in
    'container:container inspect dbmigratepostgres-source'|'volume:volume inspect dbmigratepostgres-source-data'|'network:network inspect dbmigratepostgres') exit 0 ;;
esac
exit 1
DOCKER
    chmod +x "$SAFETY_WORK/bin/docker"
}

@test "migration suite skipped without authorization does not touch pre-existing resources" {
    prepare_migration_guard_fixture
    mkdir "$SAFETY_WORK/migration-fixture"; printf original > "$SAFETY_WORK/migration-fixture/marker"
    run env E2E_ALLOW= E2E_DB=postgres PATH="$SAFETY_WORK/bin:$PATH" bats "$SAFETY_WORK/tests/migration.bats"
    [ "$status" = 0 ]
    [ "$(cat "$SAFETY_WORK/migration-fixture/marker")" = original ]
    [ ! -e "$FAKE_DOCKER_LOG" ]
}

@test "migration suite refuses resource collisions without cleaning unowned fixtures" {
    [ "$(id -u)" = 0 ] || skip "root required"
    prepare_migration_guard_fixture
    local collision
    for collision in directory container volume network; do
        export COLLISION_RESOURCE="$collision"
        if [ "$collision" = directory ]; then
            mkdir "$SAFETY_WORK/migration-fixture"; printf original > "$SAFETY_WORK/migration-fixture/marker"
        fi
        run env E2E_ALLOW=1 E2E_DB=postgres PATH="$SAFETY_WORK/bin:$PATH" bats "$SAFETY_WORK/tests/migration.bats"
        [ "$status" != 0 ]; [[ "$output" == *"Migration fixture already exists"* ]]
        if [ "$collision" = directory ]; then
            [ "$(cat "$SAFETY_WORK/migration-fixture/marker")" = original ]
            rm -rf -- "$SAFETY_WORK/migration-fixture"
        else
            [ ! -e "$SAFETY_WORK/migration-fixture" ]
            ! grep -Eq '(^rm | (rm|create) )' "$FAKE_DOCKER_LOG"
        fi
    done
}

@test "database identifiers reject SQL/YAML injection and excessive lengths before deployment" {
    local db key value
    for db in postgres mysql; do
        for key in name user; do
            for value in "name'; SELECT 1; --" 'bad`name' 'bad"name' 'bad:name' "$(printf '%065d' 0)"; do
                run bash "$DEPLOY" --domain x.test --db-type "$db" --no-ssl --dry-run "--db-$db-$key" "$value"
                [ "$status" -eq 1 ]
                [[ "$output" == *"Invalid database $key"* ]]
            done
        done
    done
}

@test "database passwords accept quotes and backslashes but reject control characters" {
    export TEST_DB_SECRET=$'Complex_1\'"\\ #${NOT_EXPANDED}'
    local db
    for db in postgres mysql; do
        run bash -c '
            source "$1"; DRY_RUN=true; LARAVEL_VERSION="$DEFAULT_LARAVEL_VERSION"
            parse_args --domain x.test --db-type "$2" --no-ssl --db-native --db-root-password Native_root_1 "--db-$2-password" "$TEST_DB_SECRET"
            if [ "$2" = postgres ]; then test "$DB_POSTGRES_PASSWORD" = "$TEST_DB_SECRET"
            else test "$DB_MYSQL_PASSWORD" = "$TEST_DB_SECRET"; fi
        ' _ "$DEPLOY" "$db"
        [ "$status" -eq 0 ]
        run bash "$DEPLOY" --domain x.test --db-type "$db" --no-ssl --dry-run "--db-$db-password" $'secret\nINJECTED=yes'
        [ "$status" -eq 1 ]
        [[ "$output" == *"must not contain control characters"* ]]
    done
}

@test "containerized MySQL refuses unsafe image initializer passwords before Docker" {
    local flag value
    for flag in --db-mysql-password --db-mysql-root-password; do
        for value in "quote'1" 'quote"1' 'slash\1'; do
            run bash "$DEPLOY" --domain x.test --db-type mysql --no-ssl --dry-run "$flag" "$value"
            [ "$status" -eq 1 ]
            [[ "$output" == *"Containerized MySQL passwords cannot contain quotes or backslashes"* ]]
        done
    done
}

@test "official MySQL refuses root as the application user before Docker" {
    run_deploy --domain x.test --db-type mysql --no-ssl --dry-run --db-mysql-user root
    [ "$status" = 1 ]; [[ "$output" == *"requires a separate application user"* ]]
}

@test "Compose reads the exact database secrets written to the project env" {
    export TEST_DB_SECRET=$'Complex_1\'"\\ #${NOT_EXPANDED}\\\\\\'
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK"; SLUG=site; DOMAIN=x.test; DB_TYPE=mysql
        DB_MYSQL_PASSWORD="$TEST_DB_SECRET"; DB_MYSQL_ROOT_PASSWORD="$TEST_DB_SECRET"
        write_project_env
        printf "services:\n  check:\n    image: busybox\n    environment:\n      CHECK: \${DB_MYSQL_PASSWORD}\n      ROOT: \${DB_MYSQL_PASSWORD_ROOT}\n" > "$PROJECT_DIR/compose.yml"
        docker compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/compose.yml" config --environment |
            python3 -c "import os,sys; e=dict(line.rstrip(\"\n\").split(\"=\",1) for line in sys.stdin if \"=\" in line); assert e[\"DB_MYSQL_PASSWORD\"] == e[\"DB_MYSQL_PASSWORD_ROOT\"] == os.environ[\"TEST_DB_SECRET\"]"
    ' _ "$DEPLOY"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "native SQL client errors are fatal and are not reported as existing objects" {
    local db
    for db in postgres mysql; do
        run bash -c '
            source "$1"
            DB_TYPE="$2"; DB_NATIVE=true; DB_ROOT_PASSWORD=fake
            DB_POSTGRES_NAME=db; DB_POSTGRES_USER=user; DB_POSTGRES_PASSWORD=fake
            DB_MYSQL_NAME=db; DB_MYSQL_USER=user; DB_MYSQL_PASSWORD=fake
            psql() { :; }
            sudo() {
                case " $* " in *" -c SELECT 1; "*) return 0 ;; esac
                cat >/dev/null; echo "permission denied" >&2; return 1
            }
            mysql() {
                case " $* " in *" -e SELECT 1; "*) return 0 ;; esac
                cat >/dev/null; echo "permission denied" >&2; return 1
            }
            create_native_database
        ' _ "$DEPLOY" "$db"
        [ "$status" -eq 1 ]
        [[ "$output" == *"Failed to create native"* ]]
        [[ "$output" != *"already exists"* ]]
        [[ "$output" != *"database db created"* ]]
    done
}

make_archive_project() {
    mkdir -p "$SAFETY_WORK/site/public_html"
    printf 'root-secret\n' > "$SAFETY_WORK/site/.env"
    printf 'app-secret\n' > "$SAFETY_WORK/site/public_html/.env"
}

run_archive() {
    run bash -c '
        source "$1"
        CREATE_BACKUP=true; SLUG="sqlzip-${BATS_TEST_NUMBER}-$$"; PROJECT_DIR="$SAFETY_WORK/site"
        if [ "${COLLISION_KIND:-}" ]; then
            date() { echo fixed; }
            mkdir -p "$SAFETY_WORK/victim"
            printf original > "$SAFETY_WORK/victim/file"
            if [ "$COLLISION_KIND" = symlink ]; then
                ln -s "$SAFETY_WORK/victim/file" "/tmp/${SLUG}_fixed.zip"
            else
                printf original > "/tmp/${SLUG}_fixed.zip"
            fi
            cleanup_collision() {
                cat "/tmp/${SLUG}_fixed.zip" > "$SAFETY_WORK/collision-content"
                if [ -L "/tmp/${SLUG}_fixed.zip" ]; then touch "$SAFETY_WORK/collision-link"; fi
                rm -f -- "/tmp/${SLUG}_fixed.zip"
            }
            trap cleanup_collision EXIT
        fi
        zip() {
            printf "%s" "$3" > "$SAFETY_WORK/staging-path"
            test "$(stat -c %a "$(dirname "$3")")" = 700 || return 1
            if [ "${ZIP_FAIL:-0}" = 1 ]; then printf partial > "$3"; return 7; fi
            if [ "${ZIP_INTERRUPT:-0}" = 1 ]; then printf partial > "$3"; kill -TERM "$BASHPID"; return 7; fi
            command zip "$@" || return
            test "$(stat -c %a "$3")" = 600 || return 1
        }
        umask 000
        create_project_backup
        test "$(umask)" = 0000
        printf "%s" "$BACKUP_FILE_PATH" > "$SAFETY_WORK/backup-path"
    ' _ "$DEPLOY"
}

@test "ZIP is private from creation, preserves the caller umask and contains both env files" {
    require_root
    make_archive_project
    run_archive
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    local archive; archive=$(cat "$SAFETY_WORK/backup-path")
    [ "$(stat -c %a "$archive")" = 600 ]
    run sudo -u nobody cat "$archive"
    [ "$status" -ne 0 ]
    python3 - "$archive" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.read("site/.env") == b"root-secret\n"
    assert archive.read("site/public_html/.env") == b"app-secret\n"
PY
    [ ! -d "$(dirname "$(cat "$SAFETY_WORK/staging-path")")" ]
    rm -f -- "$archive"
}

@test "ZIP publication refuses existing files and symlinks without changing them" {
    make_archive_project
    local kind
    for kind in file symlink; do
        export COLLISION_KIND="$kind"
        run_archive
        [ "$status" -eq 1 ]
        [[ "$output" == *"Failed to create the backup archive"* ]]
        [ "$(cat "$SAFETY_WORK/victim/file")" = original ]
        [ "$(cat "$SAFETY_WORK/collision-content")" = original ]
        if [ "$kind" = symlink ]; then [ -f "$SAFETY_WORK/collision-link" ]; fi
        [ "$(cat "$SAFETY_WORK/site/.env")" = root-secret ]
        [ ! -d "$(dirname "$(cat "$SAFETY_WORK/staging-path")")" ]
    done
}

@test "failed or interrupted ZIP creation removes partial data and records no success" {
    make_archive_project
    local failure
    for failure in ZIP_FAIL ZIP_INTERRUPT; do
        export "$failure=1"
        run_archive
        [ "$status" -eq 1 ]
        [[ "$output" == *"Failed to create the backup archive"* ]]
        [ ! -d "$(dirname "$(cat "$SAFETY_WORK/staging-path")")" ]
        [ "$(cat "$SAFETY_WORK/site/.env")" = root-secret ]
        [ ! -f "$SAFETY_WORK/backup-path" ]
        unset "$failure"
    done
}

@test "the shared proxy and path traversal are refused by every management script" {
    require_root
    local script slug
    for script in deploy-laravel.sh activate.sh deactivate.sh remove.sh update.sh backup.sh; do
        for slug in nginxproxy ../outside; do
            if [ "$script" = deploy-laravel.sh ]; then
                run bash "${REPO_ROOT}/${script}" --slug "$slug" --domain x.test --db-type postgres --no-ssl
            elif [ "$script" = remove.sh ]; then
                run bash "${REPO_ROOT}/${script}" --slug "$slug" --domain x.test
            elif [ "$script" = backup.sh ]; then
                run bash "${REPO_ROOT}/${script}" --slug "$slug" list
            else
                run bash "${REPO_ROOT}/${script}" --slug "$slug"
            fi
            [ "${status}" -eq 1 ]
            if [ "$slug" = nginxproxy ]; then
                [[ "${output}" == *"reserved for the shared reverse proxy"* ]]
            else
                [[ "${output}" == *"Invalid slug"* ]]
            fi
        done
    done
}

@test "redeploy refuses before Docker and preserves secrets, uploads, backups and proxy config" {
    require_root
    mkdir -p "${SAFETY_WORK}/www/site/public_html/storage/app" "${SAFETY_WORK}/www/site/backups" "${SAFETY_WORK}/www/nginxproxy/sites"
    printf 'original-key' > "${SAFETY_WORK}/www/site/.env"
    printf 'upload' > "${SAFETY_WORK}/www/site/public_html/storage/app/file"
    printf 'dump' > "${SAFETY_WORK}/www/site/backups/site.dump"
    printf 'proxy' > "${SAFETY_WORK}/www/nginxproxy/sites/site.conf"
    run bash -c '
        source "$1"
        WWW_DIR="$SAFETY_WORK/www"
        PROXY_DIR="$WWW_DIR/nginxproxy"
        docker() { touch "$SAFETY_WORK/docker-called"; return 1; }
        main --slug site --domain x.test --db-type postgres --no-ssl
    ' _ "${DEPLOY}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Project path already exists"* ]]
    [ ! -e "${SAFETY_WORK}/docker-called" ]
    [ "$(cat "${SAFETY_WORK}/www/site/.env")" = original-key ]
    [ "$(cat "${SAFETY_WORK}/www/site/public_html/storage/app/file")" = upload ]
    [ "$(cat "${SAFETY_WORK}/www/site/backups/site.dump")" = dump ]
    [ "$(cat "${SAFETY_WORK}/www/nginxproxy/sites/site.conf")" = proxy ]
}

@test "existing files and dangling symlinks cannot be replaced by project creation" {
    mkdir -p "${SAFETY_WORK}/www"
    touch "${SAFETY_WORK}/www/file"
    ln -s "${SAFETY_WORK}/missing" "${SAFETY_WORK}/www/link"
    local slug
    for slug in file link; do
        run bash -c 'source "$1"; WWW_DIR="$SAFETY_WORK/www"; SLUG="$2"; create_project' _ "${DEPLOY}" "$slug"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"Project path already exists"* ]]
    done
    [ -f "${SAFETY_WORK}/www/file" ]
    [ -L "${SAFETY_WORK}/www/link" ]
}

@test "a project created after preflight is not overwritten" {
    mkdir -p "${SAFETY_WORK}/www"
    run bash -c '
        source "$1"
        SLUG=site; WWW_DIR="$SAFETY_WORK/www"
        check_project_target() {
            PROJECT_DIR="$WWW_DIR/$SLUG"
            mkdir "$PROJECT_DIR"
            echo competing-project > "$PROJECT_DIR/marker"
        }
        create_project
    ' _ "${DEPLOY}"
    [ "${status}" -eq 1 ]
    [ "$(cat "${SAFETY_WORK}/www/site/marker")" = competing-project ]
    [ ! -e "${SAFETY_WORK}/www/site/docker-compose.yml" ]
}

@test "project secrets have mode 600 even with a permissive caller umask" {
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK"; SLUG=site; DOMAIN=x.test; DB_TYPE=postgres
        DB_POSTGRES_PASSWORD=fake; REDIS_PASSWORD=fake
        umask 000
        write_project_env
        test "$(stat -c %a "$PROJECT_DIR/.env")" = 600
        test "$(umask)" = 0000
    ' _ "${DEPLOY}"
    [ "${status}" -eq 0 ]
}

configure_env() {
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK/project"; SLUG=site; DOMAIN=x.test; DB_TYPE=postgres
        DB_POSTGRES_NAME=db; DB_POSTGRES_USER=user; DB_POSTGRES_PASSWORD=fake
        docker() { touch "$SAFETY_WORK/migration-called"; return "${MIGRATION_EXIT:-0}"; }
        configure_laravel_env
        echo configured
    ' _ "${DEPLOY}"
}

@test "new Laravel configuration is production, keeps APP_KEY and protects its env" {
    mkdir -p "${SAFETY_WORK}/project/public_html"
    printf 'APP_ENV=local\nAPP_DEBUG=true\nAPP_KEY=original-key\nCUSTOM=keep\n' > "${SAFETY_WORK}/project/public_html/.env"
    configure_env
    [ "${status}" -eq 0 ]
    local file="${SAFETY_WORK}/project/public_html/.env"
    [ "$(env_val "$file" APP_ENV)" = production ]
    [ "$(env_val "$file" APP_DEBUG)" = false ]
    [ "$(env_val "$file" APP_KEY)" = original-key ]
    [ "$(env_val "$file" CUSTOM)" = keep ]
    [ "$(stat -c %a "$file")" = 600 ]
}

@test "a failed initial migration aborts instead of declaring a configured application" {
    mkdir -p "${SAFETY_WORK}/project/public_html"
    touch "${SAFETY_WORK}/project/public_html/.env"
    export MIGRATION_EXIT=1
    configure_env
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to run Laravel migrations"* ]]
    [[ "${output}" != *"configured"* ]]
}

@test "missing Laravel env aborts before migration" {
    configure_env
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Laravel .env file not found"* ]]
    [ ! -e "${SAFETY_WORK}/migration-called" ]
}

make_restore() {
    mkdir -p "${SAFETY_WORK}/project" "${SAFETY_WORK}/backups" "${SAFETY_WORK}/bin" "${SAFETY_WORK}/tmp"
    touch "${SAFETY_WORK}/project/.env"
    bash -c 'source "$1"; PROJECT_DIR="$SAFETY_WORK/project"; BACKUP_KEEP_DAYS=7; mod_backup_install' _ "${REPO_ROOT}/modules/backup.sh"
    sed "s|/backups/|${SAFETY_WORK}/backups/|g" "${SAFETY_WORK}/project/.config/backup/restore.sh" > "${SAFETY_WORK}/restore.sh"
    cat > "${SAFETY_WORK}/bin/mysql" <<'SH'
#!/bin/sh
touch "$SAFETY_WORK/mysql-called"
cat > "$SAFETY_WORK/imported.sql"
exit "${MYSQL_EXIT:-0}"
SH
    chmod +x "${SAFETY_WORK}/bin/mysql"
    export PATH="${SAFETY_WORK}/bin:${PATH}" TMPDIR="${SAFETY_WORK}/tmp"
    export DB_PASSWORD=fake DB_HOST=fake DB_PORT=3306 DB_USER=fake DB_NAME=fake
}

@test "a corrupt MySQL archive fails before the database client is called" {
    make_restore
    printf 'not gzip' > "${SAFETY_WORK}/backups/corrupt.sql.gz"
    run /bin/sh "${SAFETY_WORK}/restore.sh" corrupt.sql.gz
    [ "${status}" -ne 0 ]
    [ ! -e "${SAFETY_WORK}/mysql-called" ]
    [[ "${output}" != *"restored"* ]]
    [ -z "$(ls -A "${SAFETY_WORK}/tmp")" ]
}

@test "a truncated MySQL archive fails even if it yields partial SQL" {
    make_restore
    printf 'CREATE TABLE marker (id int);\n' | gzip > "${SAFETY_WORK}/backups/truncated.sql.gz"
    truncate -s -8 "${SAFETY_WORK}/backups/truncated.sql.gz"
    run /bin/sh "${SAFETY_WORK}/restore.sh" truncated.sql.gz
    [ "${status}" -ne 0 ]
    [ ! -e "${SAFETY_WORK}/mysql-called" ]
    [ -z "$(ls -A "${SAFETY_WORK}/tmp")" ]
}

@test "valid MySQL SQL is imported and a database error is propagated" {
    make_restore
    printf 'CREATE TABLE marker (id int);\n' | gzip > "${SAFETY_WORK}/backups/valid.sql.gz"
    run /bin/sh "${SAFETY_WORK}/restore.sh" valid.sql.gz
    [ "${status}" -eq 0 ]
    [ "$(cat "${SAFETY_WORK}/imported.sql")" = 'CREATE TABLE marker (id int);' ]
    [ -z "$(ls -A "${SAFETY_WORK}/tmp")" ]
    export MYSQL_EXIT=2
    run /bin/sh "${SAFETY_WORK}/restore.sh" valid.sql.gz
    [ "${status}" -eq 2 ]
    [[ "${output}" != *"restored"* ]]
    [ -z "$(ls -A "${SAFETY_WORK}/tmp")" ]
}

@test "dump preflight failure leaves application services untouched" {
    mkdir -p "${SAFETY_WORK}/backups"
    touch "${SAFETY_WORK}/backups/corrupt.sql.gz"
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK"; DUMP_FILE=corrupt.sql.gz; ASSUME_YES=true
        dc() { printf "%q " "$@" >> "$SAFETY_WORK/calls"; printf "\n" >> "$SAFETY_WORK/calls"; return 1; }
        do_restore
    ' _ "${REPO_ROOT}/backup.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"database and application services were not changed"* ]]
    [ "$(wc -l < "${SAFETY_WORK}/calls")" -eq 1 ]
    if grep -Eq 'artisan|stop|start|/scripts/restore.sh' "${SAFETY_WORK}/calls"; then return 1; fi
}

@test "an empty compressed SQL dump is refused before maintenance or stopping services" {
    mkdir -p "${SAFETY_WORK}/backups"
    printf '' | gzip > "${SAFETY_WORK}/backups/empty.sql.gz"
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK"; DUMP_FILE=empty.sql.gz; ASSUME_YES=true
        dc() {
            while [[ "$1" != -ec ]]; do shift; done
            local check="$2"
            check="${check//\/backups\//$SAFETY_WORK/backups/}"
            /bin/sh -ec "$check" check-dump "$DUMP_FILE"
        }
        do_restore
    ' _ "${REPO_ROOT}/backup.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"empty SQL dump"* ]]
    [[ "${output}" == *"database and application services were not changed"* ]]
    [[ "${output}" != *"Enabling maintenance"* ]]
}

@test "restore maintenance failure aborts before stopping services or importing" {
    mkdir -p "${SAFETY_WORK}/backups"
    touch "${SAFETY_WORK}/backups/valid.dump"
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK"; DUMP_FILE=valid.dump; ASSUME_YES=true
        dc() {
            printf "%q " "$@" >> "$SAFETY_WORK/calls"; printf "\n" >> "$SAFETY_WORK/calls"
            if [[ "$*" == *check-dump* ]]; then return 0; fi
            if [[ "$*" == "config --services" ]]; then printf "php\ncron\n"; return 0; fi
            return 1
        }
        do_restore
    ' _ "${REPO_ROOT}/backup.sh"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Cannot enable maintenance mode"* ]]
    if grep -Eq '^stop |^start |/scripts/restore.sh' "${SAFETY_WORK}/calls"; then return 1; fi
}

@test "both generated database configurations keep every port private and permissions protect env" {
    require_root
    command -v docker >/dev/null || skip "Docker Compose CLI is needed (no daemon is used)"
    local db
    for db in postgres mysql; do
        run bash -c '
            source "$1"
            WWW_DIR="$SAFETY_WORK"; SLUG="$2"; DOMAIN=x.test; DB_TYPE="$2"
            PORT_HTTP=8199; PORT_HTTPS=4199; PORT_PHP=9199; PORT_REDIS=6599
            PORT_POSTGRES=5599; PORT_MYSQL=3599; REDIS_PASSWORD=fake
            DB_POSTGRES_NAME=fake; DB_POSTGRES_USER=fake; DB_POSTGRES_PASSWORD=fake
            DB_MYSQL_NAME=fake; DB_MYSQL_USER=fake; DB_MYSQL_PASSWORD=fake; DB_MYSQL_ROOT_PASSWORD=fake
            create_project
            docker compose -f "$PROJECT_DIR/docker-compose.yml" config --format json > "$SAFETY_WORK/compose.json"
            mkdir -p "$PROJECT_DIR/public_html/storage" "$PROJECT_DIR/public_html/bootstrap/cache"
            echo fake > "$PROJECT_DIR/public_html/.env"
            python3 - "$SAFETY_WORK/compose.json" "$PROJECT_DIR/public_html" <<"PY"
import json
import subprocess
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
app = Path(sys.argv[2])
for service in ("php", "nginx", "db", "redis"):
    assert all(port["host_ip"] == "127.0.0.1" for port in data["services"][service]["ports"]), service
command = [arg.replace("/var/www/html", str(app)) for arg in data["services"]["permissions"]["command"]]
subprocess.run(command, check=True)
assert (app / ".env").stat().st_mode & 0o777 == 0o600
assert (app / ".env").stat().st_uid == 1000
assert (app / "storage").stat().st_mode & 0o777 == 0o775
PY
        ' _ "${DEPLOY}" "$db"
        [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
    done
}

make_update_repo() {
    mkdir -p "${SAFETY_WORK}/upstream" "${SAFETY_WORK}/project"
    git -C "${SAFETY_WORK}/upstream" init -q -b main
    git -C "${SAFETY_WORK}/upstream" config user.name safety
    git -C "${SAFETY_WORK}/upstream" config user.email safety@example.test
    printf old > "${SAFETY_WORK}/upstream/code"
    git -C "${SAFETY_WORK}/upstream" add code
    git -C "${SAFETY_WORK}/upstream" commit -qm old
    git clone -q "${SAFETY_WORK}/upstream" "${SAFETY_WORK}/project/public_html"
    printf new > "${SAFETY_WORK}/upstream/code"
    git -C "${SAFETY_WORK}/upstream" commit -qam new
}

run_update() {
    run bash -c '
        source "$1"
        PROJECT_DIR="$SAFETY_WORK/project"; APP_DIR="$PROJECT_DIR/public_html"
        REPO_BRANCH=main; REPO_URL="$SAFETY_WORK/upstream"
        NO_MIGRATE="${TEST_NO_MIGRATE:-false}"; HARD_RESET="${TEST_HARD_RESET:-false}"
        art() {
            case "$1" in
                down)
                    test "$(cat "$APP_DIR/code")" = old || return 9
                    printf "down-old\n" >> "$SAFETY_WORK/steps"
                    [[ "${DOWN_FAIL:-0}" != 1 ]] || return 1
                    touch "$SAFETY_WORK/maintenance" ;;
                migrate) touch "$SAFETY_WORK/migration-called" ;;
                up) printf "up\n" >> "$SAFETY_WORK/steps"; rm "$SAFETY_WORK/maintenance" ;;
            esac
        }
        docker() {
            if [[ "$*" == *"composer install"* ]]; then
                test -f "$SAFETY_WORK/maintenance" || return 9
                test "$(cat "$APP_DIR/code")" = new || return 9
                printf "composer-new\n" >> "$SAFETY_WORK/steps"
                return "${COMPOSER_EXIT:-0}"
            fi
            return 0
        }
        prepare_update
        apply_update
    ' _ "${REPO_ROOT}/update.sh"
}

@test "update enters maintenance on old code before switching the real Git checkout" {
    make_update_repo
    run_update
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
    [ "$(cat "${SAFETY_WORK}/project/public_html/code")" = new ]
    [ "$(cat "${SAFETY_WORK}/steps")" = $'down-old\ncomposer-new\nup' ]
    [ ! -e "${SAFETY_WORK}/maintenance" ]
}

@test "maintenance failure leaves the old commit and dependencies untouched" {
    make_update_repo
    export DOWN_FAIL=1
    run_update
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"stopped before changing application code"* ]]
    [ "$(cat "${SAFETY_WORK}/project/public_html/code")" = old ]
    [ "$(cat "${SAFETY_WORK}/steps")" = down-old ]
}

@test "composer failure after switching code preserves maintenance and rollback instructions" {
    make_update_repo
    local previous
    previous=$(git -C "${SAFETY_WORK}/project/public_html" rev-parse HEAD)
    export COMPOSER_EXIT=1
    run_update
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Update failed at step: composer install"* ]]
    [[ "${output}" == *"reset --hard ${previous}"* ]]
    [ -e "${SAFETY_WORK}/maintenance" ]
    [ "$(cat "${SAFETY_WORK}/steps")" = $'down-old\ncomposer-new' ]
}

@test "update no-migrate changes code without running database migrations" {
    make_update_repo
    export TEST_NO_MIGRATE=true
    run_update
    [ "$status" = 0 ]
    [ "$(cat "$SAFETY_WORK/project/public_html/code")" = new ]
    [ ! -e "$SAFETY_WORK/migration-called" ]
    [ ! -e "$SAFETY_WORK/maintenance" ]
}

@test "update refuses diverged commits unless reset is explicitly requested" {
    make_update_repo
    local app="$SAFETY_WORK/project/public_html"
    git -C "$app" -c user.name=test -c user.email=test@example.test commit --allow-empty -qm divergent
    run_update
    [ "$status" = 1 ]; [[ "$output" == *"Cannot fast-forward"* ]]
    [ ! -e "$SAFETY_WORK/steps" ]
    export TEST_HARD_RESET=true
    run_update
    [ "$status" = 0 ]
    [ "$(git -C "$app" rev-parse HEAD)" = "$(git -C "$SAFETY_WORK/upstream" rev-parse HEAD)" ]
}
