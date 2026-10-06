#!/usr/bin/env bats
# Real launch options not covered by the base deployment/install suites. Disposable sandbox only.
load helpers
OPTION_CASE="${E2E_OPTION_CASE:-generated}"
E2E_DB="${E2E_DB:-postgres}"
SLUG="${OPTION_SLUG:-opt$(printf '%s' "$OPTION_CASE" | tr -cd 'a-z0-9')}"
PROJECT="/var/www/$SLUG"
DOMAIN="$SLUG.example.test"
OWN_PROJECT=false; ENDPOINT_PID=""; SSH_PID=""; SSH_FIXTURE_DIR=""
dc() { docker compose --project-directory "$PROJECT" -f "$PROJECT/docker-compose.yml" "$@"; }
art() { dc run --rm -T artisan "$@"; }
options_count() { art tinker --execute='echo "OPTIONS_COUNT=".DB::table("options_marker")->count()."\n";' | sed -n 's/^OPTIONS_COUNT=\([0-9][0-9]*\)$/\1/p'; }

setup_file() {
    [ "${E2E_ALLOW:-}" = 1 ] || skip "use E2E_ALLOW=1 in the disposable sandbox"
    [ "$(id -u)" = 0 ] || skip "root required"
    [[ "$E2E_DB" = postgres || "$E2E_DB" = mysql ]] || return 1
    [ ! -e "$PROJECT" ] && [ ! -L "$PROJECT" ] || return 1
    local args=(--slug "$SLUG" --domain "$DOMAIN" --db-type "$E2E_DB" --no-ssl)
    case "$OPTION_CASE" in
        generated)
            args=(--domain example.test --db-type "$E2E_DB" --no-ssl --create-dhparam --create-backup --endpoint http://127.0.0.1:18090/deploy)
            cat > "$BATS_FILE_TMPDIR/endpoint.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys
class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):
        Path(sys.argv[1]).write_bytes(self.rfile.read(int(self.headers['Content-Length'])))
        self.send_response(201)
        self.end_headers()
    def log_message(self, *args): pass
HTTPServer(('127.0.0.1', 18090), Handler).serve_forever()
PY
            python3 "$BATS_FILE_TMPDIR/endpoint.py" "$BATS_FILE_TMPDIR/payload.json" > "$BATS_FILE_TMPDIR/endpoint.log" 2>&1 3>&- 4>&- </dev/null & ENDPOINT_PID=$!
            endpoint_ready() { curl --max-time 2 -s -o /dev/null http://127.0.0.1:18090/; }; eventually 10 endpoint_ready
            ;;
        preset-admin) args+=(--preset admin-panel --filament-email admin@example.test) ;;
        preset-api) args+=(--preset api) ;;
        preset-staging) args+=(--preset staging) ;;
        native-backup)
            bash "$REPO_ROOT/tests/native-db.sh" "$E2E_DB" > "$BATS_FILE_TMPDIR/native.log" 2>&1 3>&- 4>&- </dev/null || { cat "$BATS_FILE_TMPDIR/native.log"; return 1; }
            args+=(--db-native --with backup)
            if [ "$E2E_DB" = mysql ]; then args+=(--db-root-password Root_e2e_1); fi
            ;;
        ssh-repo)
            command -v sshd >/dev/null || { echo "The sandbox requires openssh-server" >&2; return 1; }
            export SSH_WORK="$BATS_FILE_TMPDIR/upstream" SSH_BARE="$BATS_FILE_TMPDIR/remote.git"
            git clone --quiet --single-branch --branch 12.x https://github.com/laravel/laravel.git "$SSH_WORK"
            git clone --quiet --bare "$SSH_WORK" "$SSH_BARE"
            ssh-keygen -q -t ed25519 -N '' -f "$BATS_FILE_TMPDIR/deploy_key"
            ssh-keygen -q -t ed25519 -N '' -f "$BATS_FILE_TMPDIR/host_key"
            # StrictModes rejects world-writable /tmp ancestors for authorized_keys.
            SSH_FIXTURE_DIR=$(mktemp -d /root/laraship-ssh-fixture.XXXXXX)
            cp "$BATS_FILE_TMPDIR/deploy_key.pub" "$SSH_FIXTURE_DIR/authorized_keys"
            chmod 600 "$SSH_FIXTURE_DIR/authorized_keys"
            mkdir -p /run/sshd
            # Key-only loopback test server; permit the sandbox's otherwise locked root account.
            usermod -p NP root
            cat > "$BATS_FILE_TMPDIR/sshd_config" <<SSH
Port 2222
ListenAddress 127.0.0.1
HostKey $BATS_FILE_TMPDIR/host_key
AuthorizedKeysFile $SSH_FIXTURE_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
StrictModes yes
PidFile $BATS_FILE_TMPDIR/sshd.pid
LogLevel VERBOSE
SSH
            /usr/sbin/sshd -D -e -f "$BATS_FILE_TMPDIR/sshd_config" > "$BATS_FILE_TMPDIR/sshd.log" 2>&1 3>&- 4>&- </dev/null & SSH_PID=$!
            ssh_ready() { ssh-keyscan -p 2222 127.0.0.1 >/dev/null 2>&1; }; eventually 10 ssh_ready
            args+=(--repo "ssh://root@127.0.0.1:2222$SSH_BARE" --branch 12.x --deploy-key "$BATS_FILE_TMPDIR/deploy_key" --post-deploy 'touch storage/app/options-hook')
            ;;
        *) echo "Unknown E2E_OPTION_CASE: $OPTION_CASE" >&2; return 1 ;;
    esac
    export DEPLOY_LOG="$BATS_FILE_TMPDIR/deploy.log"
    if [ "$OPTION_CASE" != generated ]; then OWN_PROJECT=true; fi
    set +e
    bash "$DEPLOY" "${args[@]}" > "$DEPLOY_LOG" 2>&1
    echo "$?" > "$BATS_FILE_TMPDIR/deploy.exit"
    set -e
    if [ "$OPTION_CASE" = ssh-repo ] && [ "$(cat "$BATS_FILE_TMPDIR/deploy.exit")" != 0 ]; then cat "$BATS_FILE_TMPDIR/sshd.log"; fi
    if [ "$OPTION_CASE" = generated ] && [ -f "$BATS_FILE_TMPDIR/payload.json" ]; then
        SLUG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["slug"])' "$BATS_FILE_TMPDIR/payload.json")
        PROJECT="/var/www/$SLUG"; DOMAIN="$SLUG.example.test"; OWN_PROJECT=true
        export OPTION_SLUG="$SLUG"
    fi
}
teardown_file() {
    if [ "$OWN_PROJECT" = true ] && [ -d "$PROJECT" ]; then
        (cd "$PROJECT" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
        rm -rf -- "$PROJECT"
    fi
    if [ -n "$ENDPOINT_PID" ]; then kill "$ENDPOINT_PID" 2>/dev/null || true; wait "$ENDPOINT_PID" 2>/dev/null || true; fi
    if [ -n "$SSH_PID" ]; then kill "$SSH_PID" 2>/dev/null || true; wait "$SSH_PID" 2>/dev/null || true; fi
    if [ -n "$SSH_FIXTURE_DIR" ]; then rm -rf -- "$SSH_FIXTURE_DIR"; fi
    if [ -f "${DEPLOY_LOG:-}" ] && [ -n "${E2E_KEEP_LOG:-}" ]; then cp "$DEPLOY_LOG" "$E2E_KEEP_LOG"; fi
}

@test "$OPTION_CASE / $E2E_DB: deployment succeeds with private settings and valid Compose" {
    [ "$(cat "$BATS_FILE_TMPDIR/deploy.exit")" = 0 ] || { tail -n 40 "$DEPLOY_LOG" | strip_ansi; return 1; }
    [ "$(stat -c %a "$PROJECT/.env")" = 600 ]; [ "$(stat -c %a "$PROJECT/public_html/.env")" = 600 ]
    [ "$(env_val "$PROJECT/public_html/.env" APP_ENV)" = production ]
    dc config --quiet
    art migrate:status
}
@test "$OPTION_CASE / $E2E_DB: the application responds through the shared proxy" {
    local auth=() user password
    if [[ "$OPTION_CASE" = preset-staging ]]; then
        user=$(compose_env_val "$PROJECT/.env" AUTH_USER); password=$(compose_env_val "$PROJECT/.env" AUTH_PASSWORD)
        [ "$(curl --max-time 10 -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" http://127.0.0.1/)" = 401 ]
        auth=(-u "$user:$password")
    fi
    [ "$(curl --max-time 10 -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" "${auth[@]}" http://127.0.0.1/)" = 200 ]
}
@test "$OPTION_CASE / $E2E_DB: preset features and generated administrator credentials work" {
    case "$OPTION_CASE" in
        preset-admin)
            container_up "${SLUG}_queue"; [ "$(env_val "$PROJECT/public_html/.env" QUEUE_CONNECTION)" = redis ]
            local password; password=$(compose_env_val "$PROJECT/.env" FILAMENT_ADMIN_PASSWORD)
            [ -n "$password" ]
            run art tinker --execute="\$u=App\\Models\\User::where('email','admin@example.test')->firstOrFail(); echo Hash::check('$password',\$u->password) ? 'VALID' : 'INVALID';"
            [ "$status" = 0 ]; [[ "$output" == *VALID* && "$output" != *INVALID* ]]
            ;;
        preset-api)
            container_up "${SLUG}_horizon"
            run docker exec "${SLUG}_php" php -r 'echo ini_get("upload_max_filesize"),"/",ini_get("post_max_size");'
            [ "$status" = 0 ]; [ "$output" = 16M/16M ]
            ;;
        preset-staging)
            [ "$(env_val "$PROJECT/public_html/.env" REDIS_HOST)" = "${SLUG}_redis" ]
            [ "$(stat -c %a "$PROJECT/.config/nginx/.htpasswd")" = 600 ]
            ;;
        *) skip "only for presets" ;;
    esac
}
@test "$OPTION_CASE / $E2E_DB: generated parameters, real endpoint JSON, DH and private ZIP work" {
    [ "$OPTION_CASE" = generated ] || skip "only for generated parameters"
    [ "$(env_val "$PROJECT/.env" SITE_HOST)" = "$SLUG.example.test" ]
    openssl dhparam -in "$PROJECT/.config/nginx/dhparam.pem" -check -noout
    python3 - "$BATS_FILE_TMPDIR/payload.json" "$SLUG" "$E2E_DB" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['slug']==sys.argv[2] and p['domain']==sys.argv[2]+'.example.test'
assert p['database']['type']==sys.argv[3]
assert p['database']['password'] and p['database']['name'] and p['database']['user']
assert all(isinstance(value,int) and 1<=value<=65535 for value in p['ports'].values())
PY
    local archive; archive=$(env_val "$PROJECT/.env" BACKUP_ARCHIVE_PATH)
    [ -s "$archive" ]; [ "$(stat -c %a "$archive")" = 600 ]
}
@test "$OPTION_CASE / $E2E_DB: native database backup and restore preserve data" {
    [ "$OPTION_CASE" = native-backup ] || skip "only for native backups"
    if [ "$E2E_DB" = postgres ]; then
        local server_version client_major
        server_version=$(art tinker --execute='echo "OPTIONS_VERSION=".DB::selectOne("SHOW server_version_num")->server_version_num."\n";' | sed -n 's/^OPTIONS_VERSION=\([0-9][0-9]*\)$/\1/p')
        [ -n "$server_version" ]; client_major=$((server_version / 10000))
        grep -q "DB_IMAGE: postgres:$client_major$" "$PROJECT/docker-compose.yml"
        run docker exec "${SLUG}_backup" pg_dump --version
        [ "$status" = 0 ]; [[ "$output" == *" $client_major."* ]]
        # Automatic native selection must not change the toolkit's container defaults.
        grep -qx 'POSTGRES_IMAGE=postgres:17' "$REPO_ROOT/versions.env"
    fi
    art tinker --execute='Schema::create("options_marker",function($t){$t->id();}); DB::table("options_marker")->insert(["id"=>1]);'
    sleep 2
    run bash "$REPO_ROOT/backup.sh" --slug "$SLUG" now
    [ "$status" = 0 ]
    local extension=dump dump; if [ "$E2E_DB" = mysql ]; then extension=sql.gz; fi
    dump=$(find "$PROJECT/backups" -maxdepth 1 -type f -name "*.$extension" -printf '%f\n' | sort | tail -n1)
    [ -n "$dump" ]; [ "$(stat -c %a "$PROJECT/backups/$dump")" = 600 ]
    art tinker --execute='DB::table("options_marker")->insert(["id"=>2]);'
    [ "$(options_count)" = 2 ]
    run bash "$REPO_ROOT/backup.sh" --slug "$SLUG" restore "$dump" --yes
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(options_count)" = 1 ]
}
@test "$OPTION_CASE / $E2E_DB: SSH key cloning, hook and subsequent SSH update work" {
    [ "$OPTION_CASE" = ssh-repo ] || skip "only for SSH repositories"
    [ "$(env_val "$PROJECT/.deploy-meta" DEPLOY_KEY_FILE)" = .config/deploy_key ]
    [ "$(stat -c %a "$PROJECT/.config/deploy_key")" = 600 ]
    [ -s "$PROJECT/.config/known_hosts" ]; [ -f "$PROJECT/public_html/storage/app/options-hook" ]
    echo updated > "$SSH_WORK/public/options-ssh.txt"
    git -C "$SSH_WORK" -c user.name=fixture -c user.email=fixture@example.test add public/options-ssh.txt
    git -C "$SSH_WORK" -c user.name=fixture -c user.email=fixture@example.test commit --quiet -m 'SSH update fixture'
    git -C "$SSH_WORK" push --quiet "$SSH_BARE" 12.x
    run bash "$REPO_ROOT/update.sh" --slug "$SLUG"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$PROJECT/public_html/public/options-ssh.txt")" = updated ]
    [ ! -e "$PROJECT/public_html/storage/framework/down" ]
}

@test "$OPTION_CASE / $E2E_DB: a slow native PostgreSQL version probe stops its container process" {
    [ "$OPTION_CASE" = native-backup ] && [ "$E2E_DB" = postgres ] || skip "only for native PostgreSQL backups"
    export PROBE_SLUG="$SLUG" PROBE_PORT PROBE_NAME PROBE_USER PROBE_PASSWORD PROBE_HOST
    PROBE_PORT=$(env_val "$PROJECT/.env" DB_PORT)
    [[ "$PROBE_PORT" =~ ^[0-9]+$ ]]
    PROBE_NAME=$(compose_env_val "$PROJECT/.env" DB_POSTGRES_NAME)
    PROBE_USER=$(compose_env_val "$PROJECT/.env" DB_POSTGRES_USER)
    PROBE_PASSWORD=$(compose_env_val "$PROJECT/.env" DB_POSTGRES_PASSWORD)
    PROBE_HOST=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
    docker exec "${SLUG}_php" rm -f /tmp/laraship-native-backup-probe.pid
    local probe_started=$SECONDS
    run bash -c '
        source "$1"
        error() { echo "$*" >&2; exit 1; }
        DB_NATIVE=true; POSTGRES_IMAGE=postgres:17; SLUG="$PROBE_SLUG"
        PORT_POSTGRES="$PROBE_PORT"; DB_POSTGRES_NAME="$PROBE_NAME"
        DB_POSTGRES_USER="$PROBE_USER"; DB_POSTGRES_PASSWORD="$PROBE_PASSWORD"
        docker_bridge_ip() { printf "%s" "$PROBE_HOST"; }
        # Delay the actual authenticated query while preserving the production timeout/exec path.
        timeout() {
            local args=("$@") last=$(($# - 1)) original needle replacement
            original="${args[last]}"
            needle="echo \$db->query(\"SHOW server_version_num\")->fetchColumn();"
            replacement="file_put_contents(\"/tmp/laraship-native-backup-probe.pid\",getmypid()); echo \$db->query(\"SELECT pg_sleep(30)\")->fetchColumn();"
            args[last]="${original/"$needle"/"$replacement"}"
            [[ "${args[last]}" != "$original" ]] || return 1
            command timeout "${args[@]}"
        }
        mod_backup_postgres_image
    ' _ "$REPO_ROOT/modules/backup.sh"
    [ "$status" = 1 ]; [[ "$output" == *"Cannot detect native PostgreSQL version"* ]]
    [ "$((SECONDS - probe_started))" -ge 4 ]; [ "$((SECONDS - probe_started))" -lt 15 ]
    local probe_pid
    probe_pid=$(docker exec "${SLUG}_php" cat /tmp/laraship-native-backup-probe.pid)
    [[ "$probe_pid" =~ ^[0-9]+$ ]]
    run docker exec "${SLUG}_php" kill -0 "$probe_pid"
    [ "$status" != 0 ]
    docker exec "${SLUG}_php" rm -f /tmp/laraship-native-backup-probe.pid
}
