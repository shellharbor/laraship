#!/bin/bash
set -euo pipefail

# ============================================================
# 14-modules.sh — optional features as modules (--with)
# ============================================================
# Scenario:
#   A project with the Filament admin panel and Laravel Horizon (a Redis queue supervisor with a
#   dashboard). Horizon needs Redis, so the redis module is enabled automatically.
#
# Result:
#   - filament: the /admin panel and an administrator (name and password are generated);
#   - redis: Laravel's cache, session and queue use the project's Redis (enabled by horizon);
#   - horizon: laravel/horizon is installed and the container app_horizon runs `php artisan horizon`;
#     the dashboard is at https://app.example.com/horizon (outside APP_ENV=local define the
#     viewHorizon gate in your application).
#
# List the available modules (no root needed):
#   bash /opt/laraship/deploy-laravel.sh --list-modules
#
# Before running, change: the slug, domain and emails.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/14-modules.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 14-modules.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug app \
  --domain app.example.com \
  --db-type postgres \
  --with filament,horizon \
  --filament-email admin@example.com \
  --ssl-email admin@example.com
