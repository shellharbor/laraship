#!/bin/bash
set -euo pipefail

# ============================================================
# 11-existing-application.sh — deploy your own Laravel application from git (--repo)
# ============================================================
# Scenario:
#   The application already lives in a git repository. Instead of a fresh Laravel skeleton the
#   script clones it, installs the dependencies and prepares .env. A private repository is
#   reached over SSH with a deploy key (read-only access is enough).
#
# Result:
#   - the application is cloned into /var/www/shop/public_html (branch main);
#   - composer install --no-dev --optimize-autoloader has run, .env is created from .env.example,
#     APP_KEY is generated, the DB settings and APP_URL are written, migrations and the seeder ran;
#   - the source is recorded in /var/www/shop/.deploy-meta.
#
# Update later (fast-forward, composer, migrations, cache clear, maintenance mode):
#   sudo bash /opt/laraship/update.sh --slug shop
#
# Notes:
#   - Frontend assets must be committed or built afterwards (the php container has no Node):
#       cd /var/www/shop && docker compose run --rm npm ci && docker compose run --rm npm run build
#   - Never put credentials in the URL; the script refuses them.
#   - --install-filament and --laravel-version cannot be combined with --repo.
#
# Before running, change: the slug, domain, repository URL, key path and email.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/11-existing-application.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 11-existing-application.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --repo git@github.com:acme/shop.git \
  --branch main \
  --deploy-key /root/shop_deploy_key \
  --post-deploy 'php artisan db:seed --force' \
  --ssl-email admin@example.com
