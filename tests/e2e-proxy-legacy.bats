#!/usr/bin/env bats
# A standalone custom proxy with inline sites; only use an isolated Docker host.
load helpers

setup_file() {
    [ "${E2E_ALLOW:-}" = 1 ] || skip "use E2E_ALLOW=1 in a disposable sandbox"
    [ "$(id -u)" = 0 ] || skip "root required"
    [ ! -e /var/www/nginxproxy ] || { echo 'Legacy proxy fixture requires an empty sandbox'; return 1; }
    mkdir -p /var/www/nginxproxy /var/www/legacy-fixture
    cp "$REPO_ROOT/tests/fixtures/proxy-legacy/"* /var/www/nginxproxy/
    cp /var/www/nginxproxy/nginx.conf /var/www/legacy-fixture/original-nginx.conf
    cp /var/www/nginxproxy/docker-compose.yml /var/www/legacy-fixture/original-compose.yml
    for slug in app app2; do
        mkdir -p "/var/www/$slug"
        docker network create "$slug" >/dev/null
        docker volume create "${slug}_ssl_certificates" >/dev/null
        echo "$slug" > "/var/www/$slug/index.html"
        printf 'SITE_HOST=%s\nDB_NATIVE=false\n' "$([[ "$slug" == app ]] && echo legacy.example.test || echo app2.example.test)" > "/var/www/$slug/.env"
        printf 'fixture:{SHA}%s\n' "$(printf fixture-password | openssl sha1 -binary | openssl base64)" > "/var/www/$slug/htpasswd"
        cat > "/var/www/$slug/site.conf" <<'NGINX'
server {
    listen 80;
    root /usr/share/nginx/html;
    location ^~ /.well-known/acme-challenge/ { return 200 "fixture-acme"; }
    location / { auth_basic "Fixture"; auth_basic_user_file /etc/nginx/htpasswd; }
}
NGINX
        cat > "/var/www/$slug/docker-compose.yml" <<YAML
services:
  nginx:
    image: nginx:1.29.1-alpine
    container_name: ${slug}_nginx
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
      - ./site.conf:/etc/nginx/conf.d/default.conf:ro
      - ./htpasswd:/etc/nginx/htpasswd:ro
      - ${slug}_ssl_certificates:/etc/letsencrypt:ro
    networks:
      $slug:
        aliases: [${slug}_php]
networks:
  $slug:
    external: true
volumes:
  ${slug}_ssl_certificates:
    external: true
YAML
    done
    legacy_certificate app legacy.example.test
    cat >> /var/www/app/site.conf <<'NGINX'
server {
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/legacy.example.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/legacy.example.test/privkey.pem;
    root /usr/share/nginx/html;
}
NGINX
    for slug in app app2; do docker compose --project-directory "/var/www/$slug" up -d >/dev/null; done
    docker compose --project-name legacyoperator --project-directory /var/www/nginxproxy up -d --build >/dev/null 2>&1
    docker inspect -f '{{.Image}}' nginxproxy > /var/www/legacy-fixture/original-image
    eventually 15 legacy_body
}

teardown_file() {
    # All names and directories belong to this fixture on the explicitly disposable daemon.
    for directory in nginxproxy app2 app; do
        if [ -f "/var/www/$directory/docker-compose.yml" ]; then
            if [[ "$directory" == nginxproxy ]]; then
                docker compose --project-name legacyoperator --project-directory "/var/www/$directory" down >/dev/null 2>&1 || true
            else
                docker compose --project-directory "/var/www/$directory" down >/dev/null 2>&1 || true
            fi
        fi
    done
    docker rm -f nginxproxy app_nginx app2_nginx >/dev/null 2>&1 || true
    for slug in app app2; do
        docker network rm "$slug" >/dev/null 2>&1 || true
        docker volume rm "${slug}_ssl_certificates" >/dev/null 2>&1 || true
    done
    rm -rf /var/www/nginxproxy /var/www/app /var/www/app2 /var/www/legacy-fixture /var/www/.laraship-proxy-backups
}

legacy_certificate() {
    local slug="$1" domain="$2" directory="/var/www/legacy-fixture/$1"
    mkdir -p "$directory/live/$domain"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
        -keyout "$directory/live/$domain/privkey.pem" -out "$directory/live/$domain/fullchain.pem" >/dev/null 2>&1
    cp "$directory/live/$domain/fullchain.pem" "$directory/live/$domain/chain.pem"
    docker run --rm --entrypoint sh -v "${slug}_ssl_certificates:/out" -v "$directory:/in:ro" nginx:1.29.1-alpine -ec 'cp -a /in/live /out/'
}

legacy_body() { curl --max-time 5 -fsS -u fixture:fixture-password -H 'Host: legacy.example.test' http://127.0.0.1/; }
legacy_tls() { curl --max-time 5 -kfsS --noproxy '*' --resolve legacy.example.test:443:127.0.0.1 https://legacy.example.test/; }
new_body() { curl --max-time 5 -fsS -u fixture:fixture-password -H 'Host: app2.example.test' http://127.0.0.1/; }
register_new() {
    bash -c 'source "$1"; SLUG=app2; DOMAIN=app2.example.test; PROJECT_DIR=/var/www/app2; proxy_transaction prepare_proxy_site' _ "$DEPLOY"
}

@test "the standalone legacy proxy serves HTTP and TLS without a managed sites directory" {
    [ ! -d /var/www/nginxproxy/sites ]
    cmp /var/www/nginxproxy/nginx.conf /var/www/legacy-fixture/original-nginx.conf
    cmp /var/www/nginxproxy/docker-compose.yml /var/www/legacy-fixture/original-compose.yml
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
}

@test "a bad first adoption is rejected before touching live inline configuration" {
    run bash -c 'source "$1"; SLUG=app2; DOMAIN=app2.example.test; bad() { prepare_proxy_site; echo "invalid_legacy_fixture;" >> "$PROXY_DIR/sites/app2.conf"; }; proxy_transaction bad' _ "$DEPLOY"
    [ "$status" != 0 ]
    [ ! -d /var/www/nginxproxy/sites ]
    cmp /var/www/nginxproxy/docker-compose.yml /var/www/legacy-fixture/original-compose.yml
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
}

@test "a custom image, long binds, network mapping and dotenv inputs retain their semantics" {
    local directory="$BATS_TEST_TMPDIR/custom"
    mkdir -p "$directory/config" "$directory/sites"
    cp /var/www/legacy-fixture/original-nginx.conf "$directory/config/main.conf"
    printf 'HTTP_PORT=80\nPRIVATE_TOKEN=SyntheticDotenvSecret\n' > "$directory/.env"
    printf 'FILE_TOKEN=SyntheticEnvFileSecret\n' > "$directory/settings.env"
    sed -e s/SLUG/app2/g -e s/DOMAIN/app2.example.test/g "$REPO_ROOT/nginxproxy/site-template.conf" > "$directory/sites/app2.conf"
    bash -c 'source "$1"; PROXY_DIR="$2"; SLUG=app2; toggle_ssl_blocks comment proxy' _ "$DEPLOY" "$directory"
    cat > "$directory/docker-compose.yml" <<'YAML'
services:
  nginxproxy:
    image: nginx:1.29.1-alpine
    container_name: nginxproxy
    restart: unless-stopped
    environment:
      REFERENCE: "${PRIVATE_TOKEN}"
      INHERITED_TOKEN:
    env_file: ./settings.env
    ports: ["${HTTP_PORT:-80}:80", "443:443"]
    networks:
      app:
        aliases: [custom-proxy]
    volumes:
      - type: bind
        source: ./config/main.conf
        target: /etc/nginx/nginx.conf
        read_only: true
      - app_ssl_certificates:/etc/letsencrypt/app:ro
networks:
  app:
    external: true
volumes:
  app_ssl_certificates:
    external: true
YAML
    run env INHERITED_TOKEN=SyntheticInheritedSecret python3 "$REPO_ROOT/lib/proxy_config.py" register "$directory" --slug app2 --domain app2.example.test
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    python3 - "$directory/docker-compose.yml" <<'PY'
import json, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
value = json.loads(text)['services']['nginxproxy']
assert value['image'] == 'nginx:1.29.1-alpine'
assert value['environment']['REFERENCE'] == '${PRIVATE_TOKEN}'
assert value['environment']['INHERITED_TOKEN'] is None
assert [item['path'] if isinstance(item, dict) else item for item in value['env_file']] == ['./settings.env']
assert not any(secret in text for secret in ('SyntheticDotenvSecret', 'SyntheticEnvFileSecret', 'SyntheticInheritedSecret'))
assert value['networks']['app']['aliases'] == ['custom-proxy']
PY
    run docker compose --project-name genericcandidate --project-directory "$directory" run --rm --no-deps -T --entrypoint nginx nginxproxy -t
    [ "$status" = 0 ] || { echo "$output"; return 1; }
}

@test "adoption adds the new site and privately backs up the original custom proxy" {
    run register_new
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(new_body)" = app2 ]; [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
    [ "$(docker inspect -f '{{.Image}}' nginxproxy)" = "$(cat /var/www/legacy-fixture/original-image)" ]
    [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginxproxy)" = legacyoperator ]
    local backup; backup=$(find /var/www/.laraship-proxy-backups -path '*/original/nginx.conf' -print -quit)
    [ -n "$backup" ]; cmp "$backup" /var/www/legacy-fixture/original-nginx.conf
    [ "$(stat -c %a /var/www/.laraship-proxy-backups)" = 700 ]
    python3 - <<'PY'
import json
from pathlib import Path
directory = Path('/var/www/nginxproxy')
original = Path('/var/www/legacy-fixture/original-nginx.conf').read_text()
addition = '    # Additional sites managed by LaraShip.\n    include /etc/nginx/sites/*.conf;\n'
assert (directory / 'nginx.conf').read_text().replace(addition, '') == original
value = json.loads((directory / 'docker-compose.yml').read_text())
assert value['services']['nginxproxy']['build']['dockerfile'] == 'nginx.Dockerfile'
assert set(value['services']['nginxproxy']['networks']) == {'app', 'app2'}
assert value['volumes']['app_ssl_certificates']['external'] is True
PY
}

@test "repeated registration reloads without recreating the working custom proxy" {
    local before; before=$(docker inspect -f '{{.Id}}' nginxproxy)
    run register_new
    [ "$status" = 0 ]; [ "$(docker inspect -f '{{.Id}}' nginxproxy)" = "$before" ]
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]; [ "$(new_body)" = app2 ]
    [ "$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' -H 'Host: app2.example.test' http://127.0.0.1/)" = 401 ]
    [ "$(curl --max-time 5 -fsS -H 'Host: app2.example.test' http://127.0.0.1/.well-known/acme-challenge/probe)" = fixture-acme ]
}

@test "duplicate hostnames in included files are rejected even when nginx reports a warning only" {
    run bash -c 'source "$1"; conflict() { printf "server { listen 80; server_name legacy.example.test; return 200 wrong; }\n" > "$PROXY_DIR/sites/conflict.conf"; }; proxy_transaction conflict' _ "$DEPLOY"
    [ "$status" != 0 ]; [[ "$output" == *"Conflicting proxy hostnames"* ]]
    [ ! -f /var/www/nginxproxy/sites/conflict.conf ]
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]; [ "$(new_body)" = app2 ]
}

@test "unrelated runtime files changed or created during validation are retained" {
    printf 'old runtime data\n' > /var/www/nginxproxy/operator.log
    run bash -c 'source "$1"; change() {
        printf "new runtime data\n" > "$WWW_DIR/nginxproxy/operator.log"
        printf "operator file\n" > "$WWW_DIR/nginxproxy/operator-created.txt"
        printf "# candidate change\n" >> "$PROXY_DIR/sites/app2.conf"
    }; proxy_transaction change' _ "$DEPLOY"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(cat /var/www/nginxproxy/operator.log)" = 'new runtime data' ]
    [ "$(cat /var/www/nginxproxy/operator-created.txt)" = 'operator file' ]
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]; [ "$(new_body)" = app2 ]
}

@test "an actual apply failure restores old connections, configuration and both routes" {
    cp /var/www/nginxproxy/docker-compose.yml "$BATS_TEST_TMPDIR/before.json"
    run bash -c '
        source "$1"
        FAIL_MARKER="$2/failed"
        docker() {
            if [[ " $* " == *" up -d "* && ! -f "$FAIL_MARKER" ]]; then touch "$FAIL_MARKER"; return 1; fi
            command docker "$@"
        }
        change() { python3 - "$PROXY_DIR/docker-compose.yml" <<PY
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); model=json.loads(path.read_text())
model["services"]["nginxproxy"]["labels"]={"io.laraship.fixture":"rollback"}
path.write_text(json.dumps(model,indent=2)+"\n")
PY
        }
        proxy_transaction change
    ' _ "$DEPLOY" "$BATS_TEST_TMPDIR"
    [ "$status" != 0 ]; [ -f "$BATS_TEST_TMPDIR/failed" ]
    cmp /var/www/nginxproxy/docker-compose.yml "$BATS_TEST_TMPDIR/before.json"
    [ "$(docker inspect -f '{{.Image}}' nginxproxy)" = "$(cat /var/www/legacy-fixture/original-image)" ]
    [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginxproxy)" = legacyoperator ]
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]; [ "$(new_body)" = app2 ]
}

@test "TLS activation for the new project retains the original site's certificate and routes" {
    legacy_certificate app2 app2.example.test
    cat >> /var/www/app2/site.conf <<'NGINX'
server {
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/app2.example.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app2.example.test/privkey.pem;
    root /usr/share/nginx/html;
}
NGINX
    docker exec app2_nginx nginx -s reload
    run bash -c 'source "$1"; SLUG=app2; proxy_transaction prepare_proxy_ssl' _ "$DEPLOY"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' -H 'Host: app2.example.test' http://127.0.0.1/)" = 301 ]
    [ "$(curl --max-time 5 -kfsS --noproxy '*' --resolve app2.example.test:443:127.0.0.1 https://app2.example.test/)" = app2 ]
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
    [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginxproxy)" = legacyoperator ]
}

@test "deactivation, activation and removal preserve the unmanaged legacy site" {
    run bash "$REPO_ROOT/deactivate.sh" --slug app2
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
    run bash "$REPO_ROOT/activate.sh" --slug app2
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(curl --max-time 5 -kfsS --noproxy '*' --resolve app2.example.test:443:127.0.0.1 https://app2.example.test/)" = app2 ]
    run bash -c 'printf "yes\n" | bash "$1/remove.sh" --slug app2 --domain app2.example.test' _ "$REPO_ROOT"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ ! -e /var/www/app2 ]; [ "$(legacy_body)" = app ]; [ "$(legacy_tls)" = app ]
}
