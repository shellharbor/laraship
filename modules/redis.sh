# shellcheck shell=bash disable=SC2154,SC2034
# ============================================================
# Module: redis — wire Redis into Laravel
# ============================================================
# Loaded by deploy-laravel.sh (--with redis, or its alias --use-redis). The Redis container
# itself is part of every project; this module only points Laravel at it.
# See modules/README.md for the module API.
# ============================================================

MOD_REDIS_DESCRIPTION="Wire Redis into Laravel: REDIS_* settings, and cache, session and queue on redis"
MOD_REDIS_REQUIRES=""

# Runs after Laravel is installed and migrated; $1 is the path of Laravel's .env
mod_redis_env() {
    local LARAVEL_ENV="$1"
    [[ -f "$LARAVEL_ENV" ]] || return 0

    info "Wiring Redis into Laravel (redis module)..."
    set_env_var "$LARAVEL_ENV" REDIS_CLIENT phpredis
    set_env_var "$LARAVEL_ENV" REDIS_HOST "${SLUG}_redis"
    set_env_var "$LARAVEL_ENV" REDIS_PORT 6379
    set_env_var "$LARAVEL_ENV" REDIS_PASSWORD "$(db_env_value "$REDIS_PASSWORD" laravel)"
    # Laravel 11+ names the cache setting CACHE_STORE, Laravel 10 CACHE_DRIVER
    if grep -qE '^#? *CACHE_DRIVER=' "$LARAVEL_ENV"; then
        set_env_var "$LARAVEL_ENV" CACHE_DRIVER redis
    else
        set_env_var "$LARAVEL_ENV" CACHE_STORE redis
    fi
    set_env_var "$LARAVEL_ENV" SESSION_DRIVER redis
    set_env_var "$LARAVEL_ENV" QUEUE_CONNECTION redis
    info "  REDIS_HOST: ${SLUG}_redis (port 6379); cache, session and queue use redis"
}

mod_redis_summary() {
    echo "REDIS (module redis):"
    echo "  Laravel cache, session and queue use redis (${SLUG}_redis)"
    echo ""
}
