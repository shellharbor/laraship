#!/usr/bin/env bats
# Private temporary fixtures; no daemon or existing application is changed.
load helpers
setup() { export HARDEN_WORK="$BATS_TEST_TMPDIR/hardening"; mkdir -p "$HARDEN_WORK"; }

@test "native PostgreSQL backup selects the connected server major and keeps secrets out of arguments" {
    export TEST_SECRET=$'native quote\' and " \\ ${literal}'
    run bash -c '
        source "$1"
        error() { echo "$*" >&2; exit 1; }
        DB_TYPE=postgres; DB_NATIVE=true; POSTGRES_IMAGE=postgres:17; SLUG=site
        PORT_POSTGRES=5544; DB_POSTGRES_NAME=app; DB_POSTGRES_USER=appuser; DB_POSTGRES_PASSWORD="$TEST_SECRET"
        docker_bridge_ip() { echo 172.17.0.1; }
        timeout() { [ "$1" = 10 ] || return 1; shift; "$@"; }
        docker() { printf "%s\n" "$@" > "$HARDEN_WORK/probe-args"; cat > "$HARDEN_WORK/probe-input"; printf "%s" "$FIXTURE_VERSION"; }
        for FIXTURE_VERSION in 160015 170011; do
            mod_backup_compose > "$HARDEN_WORK/$FIXTURE_VERSION.yml" || exit 1
            [ "$POSTGRES_IMAGE" = postgres:17 ] || exit 1
        done
    ' _ "$REPO_ROOT/modules/backup.sh"
    [ "$status" = 0 ]
    grep -qx '        DB_IMAGE: postgres:16' "$HARDEN_WORK/160015.yml"
    grep -qx '        DB_IMAGE: postgres:17' "$HARDEN_WORK/170011.yml"
    grep -qx '      DB_PORT: "5544"' "$HARDEN_WORK/160015.yml"
    grep -qx 'site_php' "$HARDEN_WORK/probe-args"
    grep -qx 'timeout' "$HARDEN_WORK/probe-args"
    grep -qx -- '--kill-after=1s' "$HARDEN_WORK/probe-args"
    grep -qx '5s' "$HARDEN_WORK/probe-args"
    if grep -qF "$TEST_SECRET" "$HARDEN_WORK/probe-args"; then return 1; fi
    python3 - "$HARDEN_WORK/probe-input" <<'PY'
import os, sys
fields = open(sys.argv[1], 'rb').read().split(b'\0')
assert fields == [b'172.17.0.1', b'5544', b'app', b'appuser', os.environ['TEST_SECRET'].encode(), b'']
PY
}
@test "native PostgreSQL backup refuses failed or malformed version detection without a fallback image" {
    for fixture in failed timed-out empty 90624 16.15 160015junk; do
        run bash -c '
            source "$1"
            error() { echo "$*" >&2; exit 1; }
            DB_TYPE=postgres; DB_NATIVE=true; POSTGRES_IMAGE=postgres:17; SLUG=site
            PORT_POSTGRES=5432; DB_POSTGRES_NAME=app; DB_POSTGRES_USER=app; DB_POSTGRES_PASSWORD=test
            docker_bridge_ip() { echo 172.17.0.1; }
            timeout() { shift; "$@"; }
            docker() { cat >/dev/null; [ "$FIXTURE_VERSION" != failed ] || return 1; [ "$FIXTURE_VERSION" != timed-out ] || return 124; [ "$FIXTURE_VERSION" = empty ] || printf "%s" "$FIXTURE_VERSION"; }
            FIXTURE_VERSION="$2"
            mod_backup_compose
        ' _ "$REPO_ROOT/modules/backup.sh" "$fixture"
        [ "$status" = 1 ]
        [[ "$output" == *"native PostgreSQL"* ]]
        [[ "$output" != *"DB_IMAGE:"* ]]
    done
}
@test "container PostgreSQL and both MySQL backup modes retain configured images without a version probe" {
    run bash -c '
        source "$1"
        error() { echo "$*" >&2; exit 1; }
        SLUG=site; POSTGRES_IMAGE=postgres:17-bookworm; MYSQL_IMAGE=mysql:8.4
        DB_POSTGRES_NAME=app; DB_POSTGRES_USER=user; DB_MYSQL_NAME=app; DB_MYSQL_USER=user
        PORT_MYSQL=3306
        docker() { echo "Unexpected version probe" >&2; return 1; }
        docker_bridge_ip() { echo 172.17.0.1; }
        DB_TYPE=postgres; DB_NATIVE=false; mod_backup_compose > "$HARDEN_WORK/container-pg.yml" || exit 1
        DB_TYPE=mysql
        for DB_NATIVE in true false; do mod_backup_compose > "$HARDEN_WORK/mysql-$DB_NATIVE.yml" || exit 1; done
    ' _ "$REPO_ROOT/modules/backup.sh"
    [ "$status" = 0 ]
    grep -qx '        DB_IMAGE: postgres:17-bookworm' "$HARDEN_WORK/container-pg.yml"
    grep -qx '        DB_IMAGE: mysql:8.4' "$HARDEN_WORK/mysql-true.yml"
    grep -qx '        DB_IMAGE: mysql:8.4' "$HARDEN_WORK/mysql-false.yml"
}

@test "ports reject malformed, out-of-range and duplicate active bindings" {
    for port in abc 0 65536 -1 12:80; do
        run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --port-http "$port"
        assert_rejected "Invalid port"
    done
    run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --port-http 8080 --port-https 8080
    assert_rejected "Duplicate"
    run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --port-http 08080
    [ "$status" = 0 ]
}
@test "occupied ports abort before container creation" {
    run bash -c 'source "$1"; PORT_HTTP=8080; PORT_HTTPS=8443; PORT_PHP=9000; PORT_REDIS=6379; PORT_POSTGRES=5432
        ss() { printf "LISTEN 0 10 [::]:8080 [::]:*\n"; }; check_port_availability' _ "$DEPLOY"
    [ "$status" = 1 ]; [[ "$output" == *"8080"* ]]
}
@test "service credentials reject control characters and invalid Basic Auth usernames" {
    run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --redis-password $'bad\nvalue'
    assert_rejected "control characters"
    run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --enable-basic-auth --auth-user 'name:other'
    assert_rejected "Basic Auth username"
}
@test "endpoint preserves literal secrets and uses stdin with finite timeouts" {
    export TEST_SECRET=$'quoted"\\value # ${LITERAL}'
    run bash -c '
        source "$1"; ENDPOINT=https://example.test; SLUG=site; DOMAIN=x.test; APP_TYPE=laravel; LARAVEL_VERSION=13.0
        DB_TYPE=postgres; DB_POSTGRES_NAME=db; DB_POSTGRES_USER=user; DB_POSTGRES_PASSWORD="$TEST_SECRET"
        PORT_HTTP=8080; PORT_HTTPS=8443; PORT_PHP=9000; PORT_REDIS=6379; PORT_POSTGRES=5432
        REDIS_PASSWORD="$TEST_SECRET"; AUTH_PASSWORD="$TEST_SECRET"; AUTH_USER=test
        curl() { printf "%s\n" "$@" > "$HARDEN_WORK/args"; cat > "$HARDEN_WORK/payload"; printf "\n200"; }
        send_project_data' _ "$DEPLOY"
    [ "$status" = 0 ]
    python3 - "$HARDEN_WORK/payload" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
assert data["database"]["password"] == data["redis"]["password"] == data["basic_auth"]["password"] == os.environ["TEST_SECRET"]
assert data["ports"]["http"] == 8080
PY
    grep -qx -- --max-time "$HARDEN_WORK/args"
    grep -qx -- --connect-timeout "$HARDEN_WORK/args"
    grep -qx '@-' "$HARDEN_WORK/args"
    if grep -qF "$TEST_SECRET" "$HARDEN_WORK/args"; then return 1; fi
}
@test "MySQL private option file is protected and cleaned on client failure" {
    export TEST_SECRET=$'quote"\\ $value'
    run bash -c '
        source "$1"
        fake_client() {
            local file="${1#--defaults-extra-file=}"
            test "$(stat -c %a "$file")" = 600
            test "$(stat -c %a "$(dirname "$file")")" = 700
            printf "%s" "$file" > "$HARDEN_WORK/client-path"; cp "$file" "$HARDEN_WORK/options"
            printf "%s\n" "$@" > "$HARDEN_WORK/args"; cat > "$HARDEN_WORK/sql"; return 7
        }
        printf "%s\nSELECT 1;\n" "$TEST_SECRET" | mysql_private fake_client --binary-mode' _ "$DEPLOY"
    [ "$status" = 7 ]; [ "$(cat "$HARDEN_WORK/sql")" = 'SELECT 1;' ]
    [ ! -e "$(cat "$HARDEN_WORK/client-path")" ]
    if grep -qF "$TEST_SECRET" "$HARDEN_WORK/args"; then return 1; fi
    grep -qF 'password="quote\"\\ $value"' "$HARDEN_WORK/options"
}
make_dump() {
    mkdir -p "$HARDEN_WORK/project" "$HARDEN_WORK/bin"; touch "$HARDEN_WORK/project/.env"
    bash -c 'source "$1"; PROJECT_DIR="$HARDEN_WORK/project"; BACKUP_KEEP_DAYS=7; mod_backup_install' _ "$REPO_ROOT/modules/backup.sh"
    export DUMP_DIR="$HARDEN_WORK/project/backups"
    sed "s|/backups|$DUMP_DIR|g" "$HARDEN_WORK/project/.config/backup/dump.sh" > "$HARDEN_WORK/dump.sh"
    cat > "$HARDEN_WORK/bin/mysqldump" <<'SH'
#!/bin/sh
file="${1#--defaults-extra-file=}"
test "$(stat -c %a "$file")" = 600
test "$(stat -c %a "$(dirname "$file")")" = 700
printf '%s\n' "$@" > "$HARDEN_WORK/dump-args"
printf 'CREATE TABLE private_data (id int);\n'
exit "${DUMP_EXIT:-0}"
SH
    chmod +x "$HARDEN_WORK/bin/mysqldump"; export PATH="$HARDEN_WORK/bin:$PATH"
    export DB_TYPE=mysql DB_HOST=fake DB_PORT=3306 DB_USER=test DB_NAME=test DB_PASSWORD=test KEEP_DAYS=7 SLUG=site
}
@test "database dumps are private despite a permissive umask" {
    make_dump
    run sh -c 'umask 000; /bin/sh "$HARDEN_WORK/dump.sh"'
    [ "$status" = 0 ]; [ "$(stat -c %a "$output")" = 600 ]; [ "$(stat -c %a "$DUMP_DIR")" = 700 ]
    run sudo -u nobody cat "$output"; [ "$status" != 0 ]
    [ -z "$(find "$DUMP_DIR" -name '.site-dump.*')" ]
}
@test "failed dumps publish nothing and clean plaintext and credentials" {
    make_dump; export DUMP_EXIT=9
    run /bin/sh "$HARDEN_WORK/dump.sh"
    [ "$status" = 9 ]; [ -z "$(find "$DUMP_DIR" -name '*.sql.gz' -o -name '.site-dump.*')" ]
}
@test "dump publication refuses an existing final file" {
    make_dump
    printf '#!/bin/sh\necho 20000101-000000\n' > "$HARDEN_WORK/bin/date"; chmod +x "$HARDEN_WORK/bin/date"
    echo original > "$DUMP_DIR/site-20000101-000000.sql.gz"
    run /bin/sh "$HARDEN_WORK/dump.sh"
    [ "$status" != 0 ]; [ "$(cat "$DUMP_DIR/site-20000101-000000.sql.gz")" = original ]
    [ -z "$(find "$DUMP_DIR" -name '.site-dump.*')" ]
}
@test "a new backup worker cleans orphan staging after acquiring the dump lock" {
    make_dump; mkdir "$DUMP_DIR/.site-dump.abandoned"
    echo plaintext > "$DUMP_DIR/.site-dump.abandoned/raw.sql"
    run /bin/sh "$HARDEN_WORK/dump.sh"
    [ "$status" = 0 ]; [ ! -e "$DUMP_DIR/.site-dump.abandoned" ]
}
make_proxy_driver() {
    mkdir -p "$HARDEN_WORK/www/nginxproxy/sites" "$HARDEN_WORK/www/nginxproxy/conf.d"
    echo old > "$HARDEN_WORK/www/nginxproxy/docker-compose.yml"
    echo old > "$HARDEN_WORK/www/nginxproxy/sites/site.conf"
    echo base > "$HARDEN_WORK/www/nginxproxy/conf.d/base.conf"
    cat > "$HARDEN_WORK/proxy-driver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/deploy-laravel.sh"
WWW_DIR="$HARDEN_WORK/www"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$HARDEN_WORK/locks"
docker() {
    printf "%s\n" "$*" >> "$HARDEN_WORK/calls"
    case "$1" in
        inspect) echo true ;;
        exec) return 0 ;;
        compose)
            case " $* " in
                *" config -q "*) return "${BAD_COMPOSE:-0}" ;;
                *" run "*) return "${BAD_NGINX:-0}" ;;
                *" up "*)
                    local count=0
                    [[ ! -f "$HARDEN_WORK/up-count" ]] || count=$(cat "$HARDEN_WORK/up-count")
                    count=$((count + 1)); echo "$count" > "$HARDEN_WORK/up-count"
                    [[ "$count" != 1 || "${BAD_APPLY:-0}" != 1 ]] || return 1
                    [[ "$count" != 2 || "${BAD_ROLLBACK:-0}" != 1 ]] || return 1 ;;
            esac ;;
    esac
}
edit_candidate() {
    if [[ "${WAIT_CANDIDATE:-0}" == 1 ]]; then touch "$HARDEN_WORK/ready"; sleep 60; fi
    echo "${CHANGE_VALUE:-new}" > "$PROXY_DIR/sites/site.conf"
    echo new > "$PROXY_DIR/docker-compose.yml"; echo extra > "$PROXY_DIR/conf.d/extra.conf"
    if [[ "${LOG_ORDER:-0}" == 1 ]]; then
        echo "start-${CHANGE_VALUE}" >> "$HARDEN_WORK/order"; sleep 1; echo "end-${CHANGE_VALUE}" >> "$HARDEN_WORK/order"
    fi
}
proxy_transaction edit_candidate
SH
    chmod +x "$HARDEN_WORK/proxy-driver"; export REPO_ROOT
}
@test "invalid Compose and Nginx candidates leave live configuration unchanged" {
    make_proxy_driver
    for failure in BAD_COMPOSE BAD_NGINX; do
        run env "$failure=1" bash "$HARDEN_WORK/proxy-driver"
        [ "$status" != 0 ]; [ "$(cat "$HARDEN_WORK/www/nginxproxy/sites/site.conf")" = old ]
        [ ! -e "$HARDEN_WORK/www/nginxproxy/conf.d/extra.conf" ]
        [ -z "$(find "$HARDEN_WORK/www" -name '.laraship-proxy.*')" ]
    done
}
@test "failed proxy apply restores the exact tree and preserves bind directory inodes" {
    make_proxy_driver; local inode; inode=$(stat -c %i "$HARDEN_WORK/www/nginxproxy/sites")
    run env BAD_APPLY=1 bash "$HARDEN_WORK/proxy-driver"
    [ "$status" != 0 ]; [ "$(cat "$HARDEN_WORK/www/nginxproxy/docker-compose.yml")" = old ]
    [ "$(cat "$HARDEN_WORK/www/nginxproxy/sites/site.conf")" = old ]
    [ ! -e "$HARDEN_WORK/www/nginxproxy/conf.d/extra.conf" ]
    [ "$(stat -c %i "$HARDEN_WORK/www/nginxproxy/sites")" = "$inode" ]
    [ -z "$(find "$HARDEN_WORK/www" -name '.laraship-proxy.*')" ]
}
@test "failed proxy rollback retains recovery files and reports failure" {
    make_proxy_driver
    run env BAD_APPLY=1 BAD_ROLLBACK=1 bash "$HARDEN_WORK/proxy-driver"
    [ "$status" != 0 ]; [[ "$output" == *"Recovery files retained"* ]]
    [ -n "$(find "$HARDEN_WORK/www" -path '*/original/docker-compose.yml')" ]
}
@test "shared proxy refuses nested symlinks before callbacks can escape staging" {
    make_proxy_driver; echo protected > "$HARDEN_WORK/outside"
    rm "$HARDEN_WORK/www/nginxproxy/sites/site.conf"
    ln -s "$HARDEN_WORK/outside" "$HARDEN_WORK/www/nginxproxy/sites/site.conf"
    run bash "$HARDEN_WORK/proxy-driver"
    [ "$status" != 0 ]; [[ "$output" == *"symlinks"* ]]; [ "$(cat "$HARDEN_WORK/outside")" = protected ]
}
@test "TERM to the main PID cancels its worker and waits for cleanup" {
    make_proxy_driver
    WAIT_CANDIDATE=1 bash "$HARDEN_WORK/proxy-driver" > "$HARDEN_WORK/signal.log" 2>&1 &
    local pid=$!
    eventually 10 test -f "$HARDEN_WORK/ready"; kill -TERM "$pid"
    local result=0; wait "$pid" || result=$?; [ "$result" != 0 ]
    [ "$(cat "$HARDEN_WORK/www/nginxproxy/sites/site.conf")" = old ]
    [ -z "$(find "$HARDEN_WORK/www" -name '.laraship-proxy.*')" ]
    if pgrep -f "^bash $HARDEN_WORK/proxy-driver$"; then return 1; fi
}
@test "parallel proxy operations serialize snapshots and candidate writes" {
    make_proxy_driver
    LOG_ORDER=1 CHANGE_VALUE=a bash "$HARDEN_WORK/proxy-driver" > "$HARDEN_WORK/a.log" 2>&1 & local a=$!
    LOG_ORDER=1 CHANGE_VALUE=b bash "$HARDEN_WORK/proxy-driver" > "$HARDEN_WORK/b.log" 2>&1 & local b=$!
    wait "$a"; wait "$b"
    run cat "$HARDEN_WORK/order"
    [[ "$output" == $'start-a\nend-a\nstart-b\nend-b' || "$output" == $'start-b\nend-b\nstart-a\nend-a' ]]
    [ -f "$HARDEN_WORK/www/nginxproxy/conf.d/base.conf" ]
    [ ! -d "$HARDEN_WORK/www/nginxproxy/conf.d/conf.d" ]
}
@test "remove cancellation keeps data and domain mismatch fails before proxy edits" {
    mkdir -p "$HARDEN_WORK/www/site"; echo SITE_HOST=correct.test > "$HARDEN_WORK/www/site/.env"
    echo data > "$HARDEN_WORK/www/site/data"
    run bash -c 'source "$1"; WWW_DIR="$HARDEN_WORK/www"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$HARDEN_WORK/locks"; main --slug site --domain wrong.test' _ "$REPO_ROOT/remove.sh"
    [ "$status" != 0 ]; [[ "$output" == *"Domain mismatch"* ]]
    run bash -c 'source "$1"; WWW_DIR="$HARDEN_WORK/www"; PROXY_DIR="$WWW_DIR/nginxproxy"; LOCK_DIR="$HARDEN_WORK/locks"; main --slug site --domain correct.test <<< no' _ "$REPO_ROOT/remove.sh"
    [ "$status" = 0 ]; [ "$(cat "$HARDEN_WORK/www/site/data")" = data ]
}
@test "release CI gate validates exact commits, completed checks and latest attempts" {
    run python3 "$REPO_ROOT/tests/test_release_ci.py"
    [ "$status" = 0 ] || { echo "$output" >&2; return 1; }
}


@test "disabling TLS preserves a short neighboring HTTP server block" {
    mkdir -p "$HARDEN_WORK/project/.config/nginx"
    cp "$REPO_ROOT/laravel/.config/nginx/_site.conf" "$HARDEN_WORK/project/.config/nginx/_site.conf"
    run bash -c 'source "$1"; PROJECT_DIR="$HARDEN_WORK/project"; toggle_ssl_blocks comment' _ "$DEPLOY"
    [ "$status" = 0 ]
    grep -q '^    listen 80;' "$HARDEN_WORK/project/.config/nginx/_site.conf"
    grep -q '^#    listen 443 ssl;' "$HARDEN_WORK/project/.config/nginx/_site.conf"
    run bash -c 'source "$1"; PROJECT_DIR="$HARDEN_WORK/project"; toggle_ssl_blocks uncomment' _ "$DEPLOY"
    [ "$status" = 0 ]
    grep -q '^    listen 443 ssl;' "$HARDEN_WORK/project/.config/nginx/_site.conf"
}
@test "a failed Compose hook aborts before changing or starting module services" {
    run bash -c '
        source "$1"; ENABLED_MODULES=(fixture)
        mod_fixture_compose() { printf "  worker:\n    image: busybox\n"; return 7; }
        add_compose_service() { touch "$HARDEN_WORK/added"; }
        install_modules' _ "$DEPLOY"
    [ "$status" = 1 ]; [ ! -e "$HARDEN_WORK/added" ]
    [[ "$output" == *"failed to generate"* ]]
}
@test "failed DB readiness checks abort with a bounded retry and clean the probe" {
    run bash -c '
        source "$1"; DB_TYPE=postgres; DB_NATIVE=false; SLUG=site; DB_POSTGRES_NAME=db; DB_POSTGRES_USER=user; DB_POSTGRES_PASSWORD=pw
        timeout() { shift; "$@"; }
        docker() { [[ "$1" != rm ]] || { touch "$HARDEN_WORK/probe-cleaned"; return 0; }; return 1; }
        sleep() { SECONDS=$((SECONDS + 121)); }
        wait_for_database' _ "$DEPLOY"
    [ "$status" = 1 ]; [ -f "$HARDEN_WORK/probe-cleaned" ]
    [[ "$output" == *"did not accept"* ]]
}
@test "restore stop failure restarts services and keeps maintenance with recovery instructions" {
    mkdir -p "$HARDEN_WORK/backups"; touch "$HARDEN_WORK/backups/valid.dump"
    run bash -c '
        source "$1"; PROJECT_DIR="$HARDEN_WORK"; DUMP_FILE=valid.dump; ASSUME_YES=true
        dc() {
            printf "%s\n" "$*" >> "$HARDEN_WORK/restore-calls"
            case "$*" in "config --services") printf "php\ncron\n";; "stop "*) return 1;; esac
        }
        do_restore' _ "$REPO_ROOT/backup.sh"
    [ "$status" = 1 ]; grep -q '^start php cron' "$HARDEN_WORK/restore-calls"
    if grep -q 'artisan up' "$HARDEN_WORK/restore-calls"; then return 1; fi
    [[ "$output" == *"maintenance remains enabled"* ]]
}


@test "published project ports cannot steal shared proxy ports on first deployment" {
    for port in 80 443; do
        run_deploy --domain x.test --db-type postgres --no-ssl --dry-run --port-http "$port"
        assert_rejected "reserved for the shared proxy"
    done
}

@test "invalid module YAML is rejected before replacing the project Compose file" {
    mkdir -p "$HARDEN_WORK/project"
    printf "services:\n  app:\n    image: busybox\nnetworks: {}\n" > "$HARDEN_WORK/project/docker-compose.yml"
    local before; before=$(sha256sum "$HARDEN_WORK/project/docker-compose.yml")
    run bash -c 'source "$1"; PROJECT_DIR="$HARDEN_WORK/project"; SLUG=site; add_compose_service "  broken: [invalid"' _ "$DEPLOY"
    [ "$status" = 1 ]
    [ "$(sha256sum "$HARDEN_WORK/project/docker-compose.yml")" = "$before" ]
}

@test "Filament access configuration failure aborts its hook before administrator creation" {
    mkdir -p "$HARDEN_WORK/project/public_html/app/Models" "$HARDEN_WORK/project/public_html/config"
    printf '<?php\nclass User extends Authenticatable {}\n' > "$HARDEN_WORK/project/public_html/app/Models/User.php"
    printf '<?php\n// custom configuration\n' > "$HARDEN_WORK/project/public_html/config/laraship.php"
    local before; before=$(sha256sum "$HARDEN_WORK/project/public_html/app/Models/User.php" "$HARDEN_WORK/project/public_html/config/laraship.php")
    run bash -c '
        source "$1"; source "$SCRIPT_DIR/modules/filament.sh"
        PROJECT_DIR="$HARDEN_WORK/project"; FILAMENT_EMAIL=admin@example.test
        FILAMENT_NAME=admin; FILAMENT_PASSWORD=test; ENABLED_MODULES=(filament)
        docker() { printf "%s\n" "$*" >> "$HARDEN_WORK/filament-calls"; }
        run_module_hook install' _ "$DEPLOY"
    [ "$status" = 1 ]; [[ "$output" == *"Cannot configure Filament production access"* ]]
    [ "$(sha256sum "$HARDEN_WORK/project/public_html/app/Models/User.php" "$HARDEN_WORK/project/public_html/config/laraship.php")" = "$before" ]
    if grep -q -- '--entrypoint php' "$HARDEN_WORK/filament-calls"; then return 1; fi
}

@test "Redis environment write failure aborts without claiming successful configuration" {
    printf 'REDIS_CLIENT=old\n' > "$HARDEN_WORK/redis.env"
    run bash -c '
        source "$1"; source "$SCRIPT_DIR/modules/redis.sh"
        SLUG=site; REDIS_PASSWORD=test; ENABLED_MODULES=(redis)
        sed() { if [[ "$1" == -i ]]; then return 7; else command sed "$@"; fi; }
        run_module_hook env "$HARDEN_WORK/redis.env"' _ "$DEPLOY"
    [ "$status" = 1 ]; [[ "$output" == *"Cannot update REDIS_CLIENT"* ]]
    [ "$(cat "$HARDEN_WORK/redis.env")" = 'REDIS_CLIENT=old' ]
    [[ "$output" != *"cache, session and queue use redis"* ]]
}

@test "backup installation aborts on directory permission or script write failure" {
    local operation
    for operation in mkdir chmod cat; do
        export FAIL_OPERATION="$operation"
        mkdir -p "$HARDEN_WORK/$operation"
        run bash -c '
            source "$1"; source "$SCRIPT_DIR/modules/backup.sh"
            PROJECT_DIR="$HARDEN_WORK/$FAIL_OPERATION"; ENABLED_MODULES=(backup)
            mkdir() { [[ "$FAIL_OPERATION" != mkdir ]] || return 7; command mkdir "$@"; }
            chmod() { [[ "$FAIL_OPERATION" != chmod ]] || return 7; command chmod "$@"; }
            cat() { [[ "$FAIL_OPERATION" != cat ]] || return 7; command cat "$@"; }
            run_module_hook install' _ "$DEPLOY"
        [ "$status" = 1 ]; [[ "$output" == *"Cannot "*"backup"* ]]
        [ ! -f "$HARDEN_WORK/$operation/.config/backup/dump.sh" ]
    done
}
