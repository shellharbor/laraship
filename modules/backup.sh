# shellcheck shell=bash disable=SC2154,SC2034
# ============================================================
# Module: backup — scheduled database dumps
# ============================================================
# Loaded by deploy-laravel.sh (--with backup). Adds the service <slug>_backup, which dumps the project's
# database once at start and then every 24 hours into /var/www/<slug>/backups and deletes dumps older
# than --backup-keep days (default 7). backup.sh takes a dump on demand, lists dumps and restores one.
# See modules/README.md for the module API.
# ============================================================

MOD_BACKUP_DESCRIPTION="Scheduled database dumps in <project>/backups (daily, kept --backup-keep days, default 7); backup.sh restores them"
MOD_BACKUP_REQUIRES=""

mod_backup_validate() {
    if ! [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] || [[ "$BACKUP_KEEP_DAYS" -lt 1 || "$BACKUP_KEEP_DAYS" -gt 3650 ]]; then
        error "Invalid --backup-keep value: ${BACKUP_KEEP_DAYS} (a number of days, 1-3650)"
    fi
}

# Writes the scripts the backup container runs; they are mounted read-only from .config/backup
mod_backup_install() {
    local DIR="${PROJECT_DIR}/.config/backup"
    mkdir -p "$DIR" "${PROJECT_DIR}/backups" || error "Cannot create backup directories"
    chmod 700 "${PROJECT_DIR}/backups" || error "Cannot protect backup directory"

    cat > "${DIR}/Dockerfile" <<'DOCKER' || error "Cannot write backup Dockerfile"
ARG DB_IMAGE=postgres:17
FROM ${DB_IMAGE}
USER root
RUN if command -v flock >/dev/null; then :; \
    elif command -v apk >/dev/null; then apk add --no-cache util-linux; \
    elif command -v apt-get >/dev/null; then apt-get update && apt-get install -y --no-install-recommends util-linux && rm -rf /var/lib/apt/lists/*; \
    elif command -v microdnf >/dev/null; then microdnf install -y util-linux && microdnf clean all; \
    elif command -v dnf >/dev/null; then dnf install -y util-linux && dnf clean all; \
    elif command -v yum >/dev/null; then yum install -y util-linux && yum clean all; \
    else echo 'The backup image needs flock' >&2; exit 1; fi
DOCKER

    cat > "${DIR}/dump.sh" <<'SH' || error "Cannot write backup dump script"
#!/bin/sh
# One dump of the project database into /backups, then the retention cleanup. Prints the file name.
set -eu
umask 077
exec 9>/backups/.dump.lock
flock -x 9
# A killed predecessor released the lock; its private staging is no longer active.
find /backups -maxdepth 1 -type d -name ".${SLUG}-dump.*" -exec rm -rf -- {} +
WORK=$(mktemp -d "/backups/.${SLUG}-dump.XXXXXX")
trap 'rm -rf -- "$WORK"' 0
trap 'exit 1' 1 2 15
STAMP=$(date -u +%Y%m%d-%H%M%S)
case "$DB_TYPE" in
    postgres)
        OUT="/backups/${SLUG}-${STAMP}.dump"
        ESCAPED=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')
        printf '%s:%s:%s:%s:%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER" "$ESCAPED" > "$WORK/pgpass"
        PGPASSFILE="$WORK/pgpass" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -Fc -f "$WORK/dump" "$DB_NAME"
        ;;
    mysql)
        OUT="/backups/${SLUG}-${STAMP}.sql.gz"
        # Give the client a private option file instead of password arguments.
        ESCAPED=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '[client]\npassword="%s"\n' "$ESCAPED" > "$WORK/client.cnf"
        # Application dumps do not include instance tablespaces or replication GTIDs.
        mysqldump --defaults-extra-file="$WORK/client.cnf" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --triggers "$DB_NAME" > "$WORK/dump.sql"
        gzip -c "$WORK/dump.sql" > "$WORK/dump"
        ;;
    *)
        echo "unknown DB_TYPE: $DB_TYPE" >&2
        exit 1
        ;;
esac
ln -T -- "$WORK/dump" "$OUT"
# Retention: dumps of this project older than KEEP_DAYS days
find /backups -maxdepth 1 -type f \( -name "${SLUG}-*.dump" -o -name "${SLUG}-*.sql.gz" -o -name "${SLUG}-*.partial" \) -mtime +"$KEEP_DAYS" -delete
echo "$OUT"
SH

    cat > "${DIR}/restore.sh" <<'SH' || error "Cannot write backup restore script"
#!/bin/sh
# Restores the dump /backups/<file> into the project database (replaces its contents).
set -eu
umask 077
exec 9>/backups/.dump.lock
flock -x 9
WORK=$(mktemp -d /tmp/laraship-restore.XXXXXX)
trap 'rm -rf -- "$WORK"' 0
trap 'exit 1' 1 2 15
FILE="$1"
case "$FILE" in
    */*|*..*) echo "invalid file name" >&2; exit 1 ;;
esac
[ -f "/backups/$FILE" ] || { echo "no such dump: $FILE" >&2; exit 1; }
case "$FILE" in
    *.dump)
        pg_restore --list "/backups/$FILE" > /dev/null
        ESCAPED=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')
        printf '%s:%s:%s:%s:%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$DB_USER" "$ESCAPED" > "$WORK/pgpass"
        PGPASSFILE="$WORK/pgpass" pg_restore --exit-on-error --clean --if-exists --no-owner --no-privileges \
            -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "/backups/$FILE"
        ;;
    *.sql.gz)
        # Decompress completely before connecting to MySQL. A POSIX sh pipeline would
        # otherwise report mysql's successful exit even when gzip rejected the archive.
        SQL="$WORK/dump.sql"
        gzip -dc "/backups/$FILE" > "$SQL"
        [ -s "$SQL" ] || { echo "empty SQL dump" >&2; exit 1; }
        ESCAPED=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '[client]\npassword="%s"\n' "$ESCAPED" > "$WORK/client.cnf"
        mysql --defaults-extra-file="$WORK/client.cnf" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME" < "$SQL"
        ;;
    *)
        echo "unsupported dump type: $FILE" >&2
        exit 1
        ;;
esac
echo "restored $FILE"
SH

    cat > "${DIR}/loop.sh" <<'SH' || error "Cannot write backup loop script"
#!/bin/sh
# The container's main process: a dump right away, then one every 24 hours. A failed dump is reported
# and retried at the next round; it never stops the container.
while true; do
    /bin/sh /scripts/dump.sh || echo "backup failed at $(date -u)" >&2
    sleep 86400
done
SH
    chmod 755 "${DIR}"/*.sh || error "Cannot set backup script permissions"

    # The compose service reads the retention from the project .env
    if ! grep -q '^BACKUP_KEEP_DAYS=' "${PROJECT_DIR}/.env"; then
        {
            echo ""
            echo "BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS}"
        } >> "${PROJECT_DIR}/.env"
    fi
}

# Native PostgreSQL needs the host server's client major, independent of container DB defaults.
mod_backup_postgres_image() {
    if [[ "$DB_NATIVE" != true ]]; then printf '%s' "$POSTGRES_IMAGE"; return; fi
    local VERSION HOST
    HOST=$(docker_bridge_ip) || return 1
    # Query the same endpoint/account as Laravel. Secrets go through stdin, never exec arguments.
    if ! VERSION=$(printf '%s\0' "$HOST" "$PORT_POSTGRES" "$DB_POSTGRES_NAME" "$DB_POSTGRES_USER" "$DB_POSTGRES_PASSWORD" |
        timeout 10 docker exec -i "${SLUG}_php" timeout --kill-after=1s 5s php -r '
            $v = explode("\0", stream_get_contents(STDIN));
            try {
                $db = new PDO("pgsql:host=$v[0];port=$v[1];dbname=$v[2];connect_timeout=2", $v[3], $v[4],
                    [PDO::ATTR_TIMEOUT => 2, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
                echo $db->query("SHOW server_version_num")->fetchColumn();
            } catch (Throwable $e) { exit(1); }
        '); then
        error "Cannot detect native PostgreSQL version for the backup client"
        return 1
    fi
    if ! [[ "$VERSION" =~ ^[1-9][0-9]{5}$ ]]; then
        error "Invalid native PostgreSQL server version; backup requires PostgreSQL 10 or newer"
        return 1
    fi
    printf 'postgres:%s' "$((VERSION / 10000))"
}

# Container clients use the selected DB image; native PostgreSQL clients match the actual server.
mod_backup_compose() {
    local IMAGE DBHOST DBPORT DBNAME DBUSER PASSVAR DEPENDS=""
    if [[ "$DB_TYPE" == "postgres" ]]; then
        IMAGE=$(mod_backup_postgres_image) || return 1
        DBNAME="$DB_POSTGRES_NAME"; DBUSER="$DB_POSTGRES_USER"; PASSVAR='${DB_POSTGRES_PASSWORD}'
        if [[ "$DB_NATIVE" == true ]]; then DBHOST="$(docker_bridge_ip)"; DBPORT="$PORT_POSTGRES"; else DBHOST="${SLUG}_db"; DBPORT="5432"; fi
    else
        IMAGE="$MYSQL_IMAGE"; DBNAME="$DB_MYSQL_NAME"; DBUSER="$DB_MYSQL_USER"; PASSVAR='${DB_MYSQL_PASSWORD}'
        if [[ "$DB_NATIVE" == true ]]; then DBHOST="$(docker_bridge_ip)"; DBPORT="$PORT_MYSQL"; else DBHOST="${SLUG}_db"; DBPORT="3306"; fi
    fi
    if [[ "$DB_NATIVE" != true ]]; then
        DEPENDS=$'    depends_on:\n      - db'
    fi
    cat <<YAML
  backup:
    image: {SLUG}-backup
    build:
      context: ./.config/backup
      args:
        DB_IMAGE: ${IMAGE}
    container_name: {SLUG}_backup
    restart: always
    entrypoint: [ '/bin/sh', '/scripts/loop.sh' ]
    environment:
      SLUG: {SLUG}
      DB_TYPE: ${DB_TYPE}
      DB_HOST: ${DBHOST}
      DB_PORT: "${DBPORT}"
      DB_NAME: "${DBNAME}"
      DB_USER: "${DBUSER}"
      DB_PASSWORD: ${PASSVAR}
      KEEP_DAYS: \${BACKUP_KEEP_DAYS:-7}
    volumes:
      - ./backups:/backups
      - ./.config/backup:/scripts:ro
${DEPENDS}
    networks:
      - {SLUG}
YAML
}

mod_backup_summary() {
    echo "BACKUP (module backup):"
    echo "  Dumps:          ${PROJECT_DIR}/backups (one at start, then every 24 hours; kept ${BACKUP_KEEP_DAYS} days)"
    echo "  On demand:      sudo bash ${SCRIPT_DIR}/backup.sh --slug ${SLUG} now"
    echo "  Restore:        sudo bash ${SCRIPT_DIR}/backup.sh --slug ${SLUG} restore <file>"
    echo ""
}
