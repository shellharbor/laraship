#!/bin/bash
set -euo pipefail

# ============================================================
# 12-optional-services-and-hardening.sh — Redis, queue worker, loopback ports, upload limits
# ============================================================
# Scenario:
#   An API project that needs a queue and Redis for cache and sessions, should not expose its
#   Redis, DB and HTTP ports to the network, and accepts large uploads.
#
# Result:
#   - --use-redis: Laravel's .env gets REDIS_* and cache, session and queue use redis;
#   - --queue-worker: container api_queue runs `php artisan queue:work` (compose profile "queue",
#     stored as COMPOSE_PROFILES=queue in /var/www/api/.env, so activate.sh and deactivate.sh
#     handle it too);
#   - --bind-local: the project's HTTP/HTTPS, Redis and DB ports are published on 127.0.0.1 only
#     (the shared nginxproxy still reaches the site over the Docker network);
#   - --php-upload-max 256M: upload_max_filesize and post_max_size are set to 256M in
#     /var/www/api/.config/php/project.ini.
#
# Before running, change: the slug, domain and email.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/12-optional-services-and-hardening.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 12-optional-services-and-hardening.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug api \
  --domain api.example.com \
  --db-type postgres \
  --use-redis \
  --queue-worker \
  --bind-local \
  --php-upload-max 256M \
  --ssl-email admin@example.com
