# shellcheck shell=bash disable=SC2154,SC2034
# ============================================================
# Module: queue — a queue worker container
# ============================================================
# Loaded by deploy-laravel.sh (--with queue, or its alias --queue-worker). Adds the service
# <slug>_queue to the project's docker-compose.yml. See modules/README.md for the module API.
# ============================================================

MOD_QUEUE_DESCRIPTION="A queue worker container (php artisan queue:work); combine with redis for a Redis queue"
MOD_QUEUE_REQUIRES=""

# Runs after Laravel is installed and migrated
mod_queue_install() {
    local LARAVEL_ENV="${PROJECT_DIR}/public_html/.env" QCONN=""
    if [[ -f "$LARAVEL_ENV" ]]; then
        QCONN=$(grep -E '^QUEUE_CONNECTION=' "$LARAVEL_ENV" | head -n1 | cut -d= -f2-)
    fi
    if [[ -z "$QCONN" || "$QCONN" == "sync" ]]; then
        warn "QUEUE_CONNECTION is '${QCONN:-not set}': jobs run inside the request and the worker will stay idle."
        warn "Set QUEUE_CONNECTION (database or redis) in ${LARAVEL_ENV}, or deploy with --with redis."
    fi
}

# The service is added to the project's compose file once Laravel is installed
# (a worker started earlier would restart in a loop until artisan exists)
mod_queue_compose() {
    cat <<'YAML'
  queue:
    build:
      context: ./.docker/php
      dockerfile: php83.Dockerfile
    container_name: {SLUG}_queue
    restart: always
    volumes:
      - ./public_html:/var/www/html
    depends_on:
      - php
    working_dir: /var/www/html
    # --max-time makes the worker exit hourly; restart: always brings it back with fresh code
    command: [ 'php', 'artisan', 'queue:work', '--sleep=3', '--tries=3', '--max-time=3600' ]
    networks:
      - {SLUG}
YAML
}

mod_queue_summary() {
    echo "QUEUE (module queue):"
    echo "  Container ${SLUG}_queue runs php artisan queue:work"
    echo ""
}
