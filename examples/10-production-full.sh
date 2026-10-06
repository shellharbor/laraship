#!/bin/bash
set -euo pipefail

# ============================================================
# 10-production-full.sh — production: everything explicit, Filament, endpoint, backup
# ============================================================
# Scenario:
#   A live site where all parameters are reproducible and the project data
#   is sent to an external accounting system.
#
# Result:
#   - https://app.example.com on Laravel ^13.0 (version pinned explicitly)
#     with PostgreSQL in the app_db container (DB app_prod);
#   - fixed host ports: 8200/4200/9200/6600/5600;
#   - the Filament panel https://app.example.com/admin;
#   - JSON with the project data, including passwords, is sent by a PUT request to
#     https://api.example.com/deployments (example body: endpoint-payload.json);
#   - the archive /tmp/app_<YYYYmmdd_HHMMSS>.zip; its path is appended to .env as
#     BACKUP_ARCHIVE_PATH. The archive contains no DB data, only the project folder.
#
# New deployments already set APP_ENV=production and APP_DEBUG=false, publish
# project ports on 127.0.0.1, and protect both .env files with mode 600. Filament
# access is restricted to the provisioned administrator. After deployment,
# review application-specific settings and run artisan config:cache if needed.
#
# --create-dhparam is not added here: in the current template it does not enable
# ssl_dhparam (see README → "Known limitations").
#
# Before running, change:
#   - the slug, domain, both emails and the endpoint URL;
#   - all ChangeMe_* passwords (characters A-Za-z0-9@%_+-; in the JSON they are sent
#     without escaping);
#   - the ports, if they are taken;
#   - check that Filament 5 is compatible with the chosen Laravel version.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/10-production-full.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 10-production-full.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug app \
  --domain app.example.com \
  --laravel-version 13.0 \
  --db-type postgres \
  --db-postgres-name app_prod \
  --db-postgres-user app_prod \
  --db-postgres-password ChangeMe_PgProd1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8200 \
  --port-https 4200 \
  --port-php 9200 \
  --port-redis 6600 \
  --port-postgres 5600 \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --endpoint https://api.example.com/deployments \
  --create-backup \
  --ssl-email admin@example.com
