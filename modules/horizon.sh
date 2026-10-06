# shellcheck shell=bash disable=SC2154,SC2034
# ============================================================
# Module: horizon — Laravel Horizon
# ============================================================
# Loaded by deploy-laravel.sh (--with horizon). Installs laravel/horizon and runs
# `php artisan horizon` in its own container instead of the plain queue worker.
# It needs the redis module, which is enabled automatically. See modules/README.md.
# ============================================================

MOD_HORIZON_DESCRIPTION="Laravel Horizon: a Redis queue supervisor and the /horizon dashboard (enables redis; replaces the plain queue worker)"
MOD_HORIZON_REQUIRES="redis"

mod_horizon_validate() {
    [[ -z "$REPO_URL" ]] || error "The horizon module cannot be combined with --repo: the application manages its own dependencies (add laravel/horizon to it yourself)"
    if module_enabled queue; then
        error "The horizon module replaces the plain queue worker: use either --with horizon or --with queue (--queue-worker), not both"
    fi
}

# Runs after Laravel is installed and migrated (the redis module has already set QUEUE_CONNECTION=redis)
mod_horizon_install() {
    info "Installing Laravel Horizon..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    if docker compose run --rm composer require laravel/horizon 2>&1; then
        success "laravel/horizon installed successfully"
    else
        error "Failed to install laravel/horizon"
    fi

    if docker compose run --rm artisan horizon:install 2>&1; then
        success "Horizon assets and configuration published"
    else
        error "Failed to run horizon:install"
    fi

    cd "${SCRIPT_DIR}" || true
}

mod_horizon_compose() {
    cat <<'YAML'
  horizon:
    build:
      context: ./.docker/php
      dockerfile: php83.Dockerfile
    container_name: {SLUG}_horizon
    restart: always
    volumes:
      - ./public_html:/var/www/html
    depends_on:
      - php
      - redis
    working_dir: /var/www/html
    # horizon:terminate (used by update.sh) stops it gracefully; restart: always starts it with the new code
    command: [ 'php', 'artisan', 'horizon' ]
    networks:
      - {SLUG}
YAML
}

mod_horizon_summary() {
    echo "HORIZON (module horizon):"
    echo "  Dashboard:      ${SITE_SCHEME:-http}://${DOMAIN}/horizon (outside APP_ENV=local define the viewHorizon gate)"
    echo "  Container:      ${SLUG}_horizon runs php artisan horizon"
    echo ""
}
