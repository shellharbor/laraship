#!/usr/bin/env bats
# Logical migrations use independent data volumes; only run in a disposable Docker sandbox.
load helpers
MIGRATION_DB="${E2E_DB:-postgres}"
MIGRATION_SLUG="dbmigrate${MIGRATION_DB}"
MIGRATION_DIR="/var/www/$MIGRATION_SLUG"
SOURCE="$MIGRATION_SLUG-source"
TARGET="$MIGRATION_SLUG-target"
FIXTURE_PASSWORD='Migration_1 #${LITERAL}; value'
# UTF-8 byte escapes also work when the sandbox locale is POSIX.
FIXTURE_NOTE=$'Unicode: \xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82 / value'
ROOT_PASSWORD=Root_migration_1
OWN_DIR=false; OWN_NETWORK=false; OWN_SOURCE_VOLUME=false; OWN_TARGET_VOLUME=false
OWN_SOURCE=false; OWN_TARGET=false

server_sql() {
    local server="$1" sql="$2" password="${3:-$FIXTURE_PASSWORD}"
    if [ "$MIGRATION_DB" = postgres ]; then
        # Use the network address: upstream trusts container-local loopback connections.
        printf '%s\n%s\n' "$password" "$sql" | docker exec -i "$server" bash -ec '
            IFS= read -r PGPASSWORD; export PGPASSWORD
            exec psql -X -h "$1" -U migration_user -d migration_db -v ON_ERROR_STOP=1 -At' _ "$server"
    else
        printf '%s\n%s\n' "$password" "$sql" | docker exec -i "$server" bash -ec '
            source /kit/lib/runtime.sh
            mysql_private mysql --protocol=tcp -h 127.0.0.1 -u migration_user -D migration_db --batch --skip-column-names --default-character-set=utf8mb4'
    fi
}
start_server() {
    local server="$1" image="$2" volume="$3" password="${4:-$FIXTURE_PASSWORD}"
    if [ "$MIGRATION_DB" = postgres ]; then
        docker run -d --name "$server" --network "$MIGRATION_SLUG" \
            -e POSTGRES_USER=migration_user -e POSTGRES_DB=migration_db -e "POSTGRES_PASSWORD=$password" \
            -v "$volume:/var/lib/postgresql/data" -v "$REPO_ROOT:/kit:ro" "$image" >/dev/null
    else
        docker run -d --name "$server" --network "$MIGRATION_SLUG" \
            -e MYSQL_USER=migration_user -e MYSQL_DATABASE=migration_db -e "MYSQL_PASSWORD=$password" -e "MYSQL_ROOT_PASSWORD=$ROOT_PASSWORD" \
            -v "$volume:/var/lib/mysql" -v "$REPO_ROOT:/kit:ro" "$image" >/dev/null
    fi
    local i
    for i in $(seq 1 120); do server_sql "$server" 'SELECT 1;' >/dev/null 2>&1 && return 0; sleep 1; done
    docker logs --tail 30 "$server" >&2; return 1
}
backup_client() {
    local image="$1" host="$2"; shift 2
    docker run --rm --network "$MIGRATION_SLUG" --entrypoint /bin/sh \
        -e "SLUG=$MIGRATION_SLUG" -e "DB_TYPE=$MIGRATION_DB" -e "DB_HOST=$host" \
        -e "DB_PORT=$DB_PORT" -e DB_NAME=migration_db -e DB_USER=migration_user \
        -e "DB_PASSWORD=$FIXTURE_PASSWORD" -e KEEP_DAYS=7 \
        -v "$MIGRATION_DIR/.config/backup:/scripts:ro" -v "$MIGRATION_DIR/backups:/backups" "$image" "$@"
}
setup_file() {
    [ "${E2E_ALLOW:-}" = 1 ] || skip "only in the disposable sandbox"
    [ "$(id -u)" = 0 ] || skip "root required"
    case "$MIGRATION_DB" in
        postgres) SOURCE_IMAGE=elestio/postgres:17; TARGET_IMAGE=$(env_val "$REPO_ROOT/versions.env" POSTGRES_IMAGE); DB_PORT=5432 ;;
        mysql) SOURCE_IMAGE=elestio/mysql:8.0; TARGET_IMAGE=$(env_val "$REPO_ROOT/versions.env" MYSQL_IMAGE); DB_PORT=3306 ;;
        *) return 1 ;;
    esac
    export SOURCE_IMAGE TARGET_IMAGE DB_PORT
    if [ -e "$MIGRATION_DIR" ] || [ -L "$MIGRATION_DIR" ] ||
        docker container inspect "$SOURCE" >/dev/null 2>&1 || docker container inspect "$TARGET" >/dev/null 2>&1 ||
        docker volume inspect "$SOURCE-data" >/dev/null 2>&1 || docker volume inspect "$TARGET-data" >/dev/null 2>&1 ||
        docker network inspect "$MIGRATION_SLUG" >/dev/null 2>&1; then
        echo "Migration fixture already exists; refusing to overwrite or clean it." >&2
        return 1
    fi
    mkdir -p "$(dirname "$MIGRATION_DIR")"
    mkdir "$MIGRATION_DIR" || return 1
    OWN_DIR=true; touch "$MIGRATION_DIR/.env"
    bash -c 'source "$1"; source "$SCRIPT_DIR/modules/backup.sh"; PROJECT_DIR="$2"; BACKUP_KEEP_DAYS=7; mod_backup_install' _ "$DEPLOY" "$MIGRATION_DIR"
    docker network create "$MIGRATION_SLUG" >/dev/null || return 1
    OWN_NETWORK=true
    docker volume create "$SOURCE-data" >/dev/null || return 1
    OWN_SOURCE_VOLUME=true
    docker volume create "$TARGET-data" >/dev/null || return 1
    OWN_TARGET_VOLUME=true
    OWN_SOURCE=true
    start_server "$SOURCE" "$SOURCE_IMAGE" "$SOURCE-data"
    OWN_TARGET=true
    start_server "$TARGET" "$TARGET_IMAGE" "$TARGET-data"
    docker build -q --build-arg "DB_IMAGE=$SOURCE_IMAGE" -t "$MIGRATION_SLUG-source-client" "$MIGRATION_DIR/.config/backup" >/dev/null
    docker build -q --build-arg "DB_IMAGE=$TARGET_IMAGE" -t "$MIGRATION_SLUG-target-client" "$MIGRATION_DIR/.config/backup" >/dev/null
}
teardown_file() {
    [ "$OWN_SOURCE" = true ] && docker rm -f "$SOURCE" >/dev/null 2>&1 || true
    [ "$OWN_TARGET" = true ] && docker rm -f "$TARGET" >/dev/null 2>&1 || true
    [ "$OWN_SOURCE_VOLUME" = true ] && docker volume rm "$SOURCE-data" >/dev/null 2>&1 || true
    [ "$OWN_TARGET_VOLUME" = true ] && docker volume rm "$TARGET-data" >/dev/null 2>&1 || true
    [ "$OWN_NETWORK" = true ] && docker network rm "$MIGRATION_SLUG" >/dev/null 2>&1 || true
    if [ "$OWN_DIR" = true ]; then rm -rf -- "$MIGRATION_DIR"; fi
}
@test "$MIGRATION_DB: source and official target authenticate and reject a wrong password" {
    [ "$(server_sql "$SOURCE" 'SELECT 1;')" = 1 ]; [ "$(server_sql "$TARGET" 'SELECT 1;')" = 1 ]
    run server_sql "$TARGET" 'SELECT 1;' wrong_password; [ "$status" != 0 ]
}
@test "$MIGRATION_DB: seed legacy data, a view and a stored routine" {
    if [ "$MIGRATION_DB" = postgres ]; then
        server_sql "$SOURCE" "CREATE TABLE marker (id integer PRIMARY KEY, note text NOT NULL);
INSERT INTO marker VALUES (1, '$FIXTURE_NOTE'), (2, 'preserved');
CREATE VIEW marker_view AS SELECT note FROM marker;
CREATE FUNCTION marker_count() RETURNS bigint LANGUAGE sql AS \$\$ SELECT count(*) FROM marker \$\$;"
    else
        server_sql "$SOURCE" "CREATE TABLE marker (id integer PRIMARY KEY, note varchar(100) NOT NULL) CHARACTER SET utf8mb4;
INSERT INTO marker VALUES (1, '$FIXTURE_NOTE'), (2, 'preserved');
CREATE VIEW marker_view AS SELECT note FROM marker;
CREATE PROCEDURE marker_count() SELECT count(*) FROM marker;"
    fi
    [ "$(server_sql "$SOURCE" 'SELECT count(*) FROM marker;')" = 2 ]
}
@test "$MIGRATION_DB: generated backup exports a private complete legacy dump" {
    run backup_client "$MIGRATION_SLUG-source-client" "$SOURCE" /scripts/dump.sh
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    local dump; dump=$(find "$MIGRATION_DIR/backups" -maxdepth 1 -type f ! -name .dump.lock | head -n1)
    [ -s "$dump" ]; [ "$(stat -c %a "$dump")" = 600 ]
    basename "$dump" > "$MIGRATION_DIR/dump-name"
}
@test "$MIGRATION_DB: generated restore imports the dump into the official image and a separate volume" {
    run server_sql "$TARGET" 'SELECT count(*) FROM marker;'; [ "$status" != 0 ]
    run backup_client "$MIGRATION_SLUG-target-client" "$TARGET" /scripts/restore.sh "$(cat "$MIGRATION_DIR/dump-name")"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(server_sql "$TARGET" 'SELECT count(*) FROM marker;')" = 2 ]
    local note; note=$(server_sql "$TARGET" 'SELECT note FROM marker WHERE id=1;')
    [ "$note" = "$FIXTURE_NOTE" ] || {
        printf 'Expected UTF-8 bytes: '; printf '%s' "$FIXTURE_NOTE" | od -An -tx1
        printf 'Restored UTF-8 bytes: '; printf '%s' "$note" | od -An -tx1
        return 1
    }
    [ "$(server_sql "$TARGET" 'SELECT count(*) FROM marker_view;')" = 2 ]
    if [ "$MIGRATION_DB" = postgres ]; then
        [ "$(server_sql "$TARGET" 'SELECT marker_count();')" = 2 ]
    else
        [ "$(server_sql "$TARGET" 'CALL marker_count();')" = 2 ]
    fi
}
@test "$MIGRATION_DB: recreating target preserves migrated data and ignores new initialization credentials" {
    docker rm -f "$TARGET" >/dev/null
    start_server "$TARGET" "$TARGET_IMAGE" "$TARGET-data" Changed_initial_password
    [ "$(server_sql "$TARGET" 'SELECT count(*) FROM marker;')" = 2 ]
    run server_sql "$TARGET" 'SELECT 1;' Changed_initial_password; [ "$status" != 0 ]
}
@test "$MIGRATION_DB: target changes do not mutate the retained rollback database" {
    server_sql "$TARGET" 'INSERT INTO marker VALUES (3, '\''target only'\'');'
    [ "$(server_sql "$TARGET" 'SELECT count(*) FROM marker;')" = 3 ]
    docker restart "$SOURCE" >/dev/null
    source_ready() { server_sql "$SOURCE" 'SELECT 1;' >/dev/null 2>&1; }; eventually 60 source_ready
    [ "$(server_sql "$SOURCE" 'SELECT count(*) FROM marker;')" = 2 ]
}
