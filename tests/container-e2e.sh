#!/usr/bin/env bash
# Real CLI/native interoperability on an explicitly disposable Linux Docker host.
set -euo pipefail
[[ "${LARASHIP_TEST_SANDBOX:-0}" == 1 || "${LARASHIP_CONTAINER_TEST_ALLOW:-0}" == 1 ]] || {
    echo 'Container E2E requires the disposable sandbox or an explicitly allowed CI runner' >&2; exit 1;
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${E2E_DB:-postgres}"
[[ "$DB" == postgres || "$DB" == mysql ]] || exit 2
SLUG="cli-$DB"
DOMAIN="$SLUG.example.test"
IMAGE=laraship:runner-test
[[ ! -e "/var/www/$SLUG" && ! -e /var/www/cli-native-guard ]] || { echo 'Fixture path collision' >&2; exit 1; }
docker build -q -t "$IMAGE" "$ROOT" >/dev/null
install -d -m 755 /var/www
install -d -m 700 /run/lock/laraship /var/backups/laraship
cli() {
    docker run --rm -i --init --network host \
        --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
        --mount type=bind,src=/var/www,dst=/var/www \
        --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
        --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
        "$IMAGE" "$@"
}
echo '==> CLI help and native DB guard'
docker run --rm "$IMAGE" update --help >/dev/null
if cli deploy --slug cli-native-guard --domain cli-native.example.test --db-type postgres --db-native --no-ssl; then exit 1; fi
[[ ! -e /var/www/cli-native-guard ]]
echo "==> deploy $DB through the actual CLI image"
cli deploy --slug "$SLUG" --domain "$DOMAIN" --db-type "$DB" --no-ssl --with backup --create-backup
ARCHIVE=$(sed -n 's/^BACKUP_ARCHIVE_PATH=//p' "/var/www/$SLUG/.env")
[[ "$ARCHIVE" == /var/backups/laraship/* && -f "$ARCHIVE" ]]
[[ "$(stat -c %a "$ARCHIVE")" == 600 ]]
[[ "$(stat -c %a "/var/www/$SLUG/.env")" == 600 ]]
cli backup now --slug "$SLUG"
echo '==> certificate presence is checked on the daemon, not the CLI filesystem'
docker run --rm --mount "type=volume,src=${SLUG}_ssl_certificates,dst=/certs" busybox:1.37.0 \
    sh -ec 'mkdir -p "/certs/live/$1"; echo fixture > "/certs/live/$1/fullchain.pem"' _ "$DOMAIN"
LIST=$(cli list | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SSL:.*YES' <<< "$LIST"
echo '==> native Bash and CLI share lifecycle and persistent paths'
bash "$ROOT/deactivate.sh" --slug "$SLUG"
cli activate --slug "$SLUG"
curl --connect-timeout 2 --max-time 10 -fsS -H "Host: $DOMAIN" "http://127.0.0.1/" >/dev/null
echo yes | cli remove --slug "$SLUG" --domain "$DOMAIN"
[[ ! -e "/var/www/$SLUG" && ! -e "$ARCHIVE" ]]
echo '==> existing native DB removal is refused before routing or confirmation'
mkdir /var/www/cli-native-guard
printf 'SITE_HOST=cli-native.example.test\nDB_NATIVE=true\nDB_POSTGRES_NAME=test\n' > /var/www/cli-native-guard/.env
if echo yes | cli remove --slug cli-native-guard --domain cli-native.example.test; then exit 1; fi
[[ -f /var/www/cli-native-guard/.env ]]
rm -rf /var/www/cli-native-guard
echo "Container E2E passed ($DB): deployment, private archive/dump, certificates, native deactivate, CLI activate/remove and native DB refusal"
