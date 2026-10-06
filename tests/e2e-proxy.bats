#!/usr/bin/env bats
# Two real sites behind the shared proxy. Use only the disposable Linux/Docker sandbox.
load helpers
setup_file() {
    [ "${E2E_ALLOW:-}" = 1 ] || skip "use E2E_ALLOW=1 in a disposable sandbox"
    [ "$(id -u)" = 0 ] || skip "root required"
    for slug in proxya proxyb; do
        mkdir -p "/var/www/$slug"
        printf 'SITE_HOST=%s.test\n' "$slug" > "/var/www/$slug/.env"
        echo "$slug" > "/var/www/$slug/index.html"
        chmod 644 "/var/www/$slug/index.html" # nginx workers read this public fixture
        docker network create "$slug" >/dev/null
        docker volume create "${slug}_ssl_certificates" >/dev/null
        cat > "/var/www/$slug/docker-compose.yml" <<YAML
services:
  nginx:
    image: nginx:1.29.1-alpine
    container_name: ${slug}_nginx
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
    networks: [$slug]
networks:
  $slug:
    external: true
    name: $slug
YAML
        docker compose --project-directory "/var/www/$slug" up -d >/dev/null
        bash -c 'source "$1"; SLUG="$2"; DOMAIN="$SLUG.test"; PROJECT_DIR="$WWW_DIR/$SLUG"; proxy_transaction prepare_proxy_site' _ "$DEPLOY" "$slug" > "/tmp/$slug-proxy.log" 2>&1
    done
}
teardown_file() {
    for slug in proxya proxyb; do
        printf 'yes\n' | bash "$REPO_ROOT/remove.sh" --slug "$slug" --domain "$slug.test" >/dev/null 2>&1 || true
        docker rm -f "${slug}_nginx" >/dev/null 2>&1 || true
        docker network rm "$slug" >/dev/null 2>&1 || true
        docker volume rm "${slug}_ssl_certificates" >/dev/null 2>&1 || true
        rm -rf "/var/www/$slug"
    done
}
site_body() { curl --max-time 5 -fsS -H "Host: $1.test" http://127.0.0.1/; }

@test "both sites are served by the shared proxy" {
    [ "$(site_body proxya)" = proxya ]; [ "$(site_body proxyb)" = proxyb ]
}
@test "bad candidate syntax leaves both live routes unchanged" {
    local before; before=$(sha256sum /var/www/nginxproxy/sites/proxya.conf)
    run bash -c 'source "$1"; broken() { echo "invalid_nginx_directive;" >> "$PROXY_DIR/sites/proxya.conf"; }; proxy_transaction broken' _ "$DEPLOY"
    [ "$status" != 0 ]
    [ "$(sha256sum /var/www/nginxproxy/sites/proxya.conf)" = "$before" ]
    [ "$(site_body proxya)" = proxya ]; [ "$(site_body proxyb)" = proxyb ]
}
@test "missing candidate network aborts without touching the other site" {
    run bash -c 'source "$1"; broken() { sed -i s/name:\ proxya/name:\ missing_proxy_network/ "$PROXY_DIR/docker-compose.yml"; }; proxy_transaction broken' _ "$DEPLOY"
    [ "$status" != 0 ]; [ "$(site_body proxyb)" = proxyb ]
}
@test "a real apply failure restores configuration and both HTTP routes" {
    run bash -c '
        source "$1"
        docker() {
            if [[ "$*" == "exec nginxproxy nginx -s reload" ]]; then return 1; fi
            command docker "$@"
        }
        edit() { echo "# harmless candidate" >> "$PROXY_DIR/sites/proxya.conf"; }
        proxy_transaction edit
    ' _ "$DEPLOY"
    [ "$status" != 0 ]
    if grep -q 'harmless candidate' /var/www/nginxproxy/sites/proxya.conf; then return 1; fi
    [ "$(site_body proxya)" = proxya ]; [ "$(site_body proxyb)" = proxyb ]
}

@test "a failed candidate TLS activation leaves both HTTP sites available" {
    run bash -c 'source "$1"; SLUG=proxya; tls() { toggle_ssl_blocks uncomment proxy; }; proxy_transaction tls' _ "$DEPLOY"
    [ "$status" != 0 ]
    [ "$(site_body proxya)" = proxya ]; [ "$(site_body proxyb)" = proxyb ]
}

@test "valid TLS application redirects HTTP and preserves ACME plus the other site" {
    local image; image=$(docker inspect -f '{{.Config.Image}}' nginxproxy)
    docker run --rm --entrypoint sh -v proxya_ssl_certificates:/cert "$image" -ec '
        mkdir -p /cert/live/proxya.test
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=proxya.test -keyout /cert/live/proxya.test/privkey.pem -out /cert/live/proxya.test/fullchain.pem >/dev/null 2>&1
        cp /cert/live/proxya.test/fullchain.pem /cert/live/proxya.test/chain.pem'
    cat > /var/www/proxya/site.conf <<'NGINX'
server {
    listen 80;
    root /usr/share/nginx/html;
    location = /.well-known/acme-challenge/probe { return 200 "acme-probe"; }
}
server {
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/proxya.test/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/proxya.test/privkey.pem;
    root /usr/share/nginx/html;
}
NGINX
    sed -i '/- .\/index.html:/a\      - ./site.conf:/etc/nginx/conf.d/default.conf:ro\n      - proxya_ssl_certificates:/etc/letsencrypt:ro' /var/www/proxya/docker-compose.yml
    printf '\nvolumes:\n  proxya_ssl_certificates:\n    external: true\n' >> /var/www/proxya/docker-compose.yml
    docker compose --project-directory /var/www/proxya up -d
    run bash -c 'source "$1"; SLUG=proxya; proxy_transaction prepare_proxy_ssl' _ "$DEPLOY"
    [ "$status" = 0 ] || { echo "$output"; return 1; }
    [ "$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' -H 'Host: proxya.test' http://127.0.0.1/)" = 301 ]
    [ "$(curl --max-time 5 -ksS --resolve proxya.test:443:127.0.0.1 --noproxy '*' https://proxya.test/)" = proxya ]
    [ "$(curl --max-time 5 -fsS -H 'Host: proxya.test' http://127.0.0.1/.well-known/acme-challenge/probe)" = acme-probe ]
    [ "$(site_body proxyb)" = proxyb ]
    run bash -c 'source "$1"; SLUG=proxya; http() { toggle_ssl_blocks comment proxy; sed -i "s|return 301 https://.*;|proxy_pass http://$SLUG;|" "$PROXY_DIR/sites/proxya.conf"; }; proxy_transaction http' _ "$DEPLOY"
    [ "$status" = 0 ]; [ "$(site_body proxya)" = proxya ]
}


@test "parallel deactivation preserves the other site's route" {
    bash "$REPO_ROOT/deactivate.sh" --slug proxya > "$BATS_TEST_TMPDIR/a.log" 2>&1 & local a=$!
    bash "$REPO_ROOT/deactivate.sh" --slug proxya > "$BATS_TEST_TMPDIR/b.log" 2>&1 & local b=$!
    wait "$a"; wait "$b"
    [ -f /var/www/nginxproxy/sites/proxya.conf.disabled ]
    [ -f /var/www/proxya/index.html ]
    [ "$(site_body proxyb)" = proxyb ]
}
@test "activation is idempotent and restores both routes" {
    run bash "$REPO_ROOT/activate.sh" --slug proxya; [ "$status" = 0 ]
    run bash "$REPO_ROOT/activate.sh" --slug proxya; [ "$status" = 0 ]
    [ "$(site_body proxya)" = proxya ]; [ "$(site_body proxyb)" = proxyb ]
}
@test "removing a disabled site retains the remaining project and route" {
    run bash "$REPO_ROOT/deactivate.sh" --slug proxya; [ "$status" = 0 ]
    run bash -c 'printf "yes\n" | bash "$1/remove.sh" --slug proxya --domain proxya.test' _ "$REPO_ROOT"
    [ "$status" = 0 ]; [ ! -e /var/www/proxya ]
    [ ! -e /var/www/nginxproxy/sites/proxya.conf.disabled ]
    [ "$(site_body proxyb)" = proxyb ]
}
@test "removing the last site leaves a valid running proxy" {
    run bash -c 'printf "yes\n" | bash "$1/remove.sh" --slug proxyb --domain proxyb.test' _ "$REPO_ROOT"
    [ "$status" = 0 ]; [ ! -e /var/www/proxyb ]
    docker exec nginxproxy nginx -t
    container_up nginxproxy
}
