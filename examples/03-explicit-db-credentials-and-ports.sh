#!/bin/bash
set -euo pipefail

# ============================================================
# 03-explicit-db-credentials-and-ports.sh — explicit DB credentials and ports
# ============================================================
# Scenario:
#   You need a predictable DB name, user, passwords and host ports,
#   for example for external monitoring or an SSH tunnel to the DB.
#
# Result:
#   - a PostgreSQL database crm_db with the user crm_user and the given password;
#   - host ports: HTTP 8150, HTTPS 4150, PHP-FPM 9150 (127.0.0.1 only),
#     Redis 6550, PostgreSQL 5550. The script does NOT check explicitly given
#     ports for being in use;
#   - Laravel connects to crm_db:5432 (internal port), while from the host the DB
#     is available on 127.0.0.1:5550.
#
# Before running, change:
#   - the slug, domain and email;
#   - all ChangeMe_* passwords to your own. Use only the characters
#     A-Za-z0-9@%_+-: values are written to .env without quotes;
#   - the ports, if they are already taken (sudo ss -tlnp).
#
# Run on the server (from any folder):
#   bash /opt/laravel-deploy/examples/03-explicit-db-credentials-and-ports.sh
# DEPLOY_DIR defaults to the laravel-deploy folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laravel-deploy bash 03-explicit-db-credentials-and-ports.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug crm \
  --domain crm.example.com \
  --db-type postgres \
  --db-postgres-name crm_db \
  --db-postgres-user crm_user \
  --db-postgres-password ChangeMe_CrmDb1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8150 \
  --port-https 4150 \
  --port-php 9150 \
  --port-redis 6550 \
  --port-postgres 5550 \
  --ssl-email admin@example.com
