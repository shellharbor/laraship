#!/bin/bash
set -euo pipefail

# ============================================================
# 01-minimal-postgres.sh — minimal deployment with PostgreSQL
# ============================================================
# Scenario:
#   Quickly bring up Laravel with PostgreSQL in a container. The slug, ports,
#   database names and all passwords are generated automatically.
#
# Result:
#   - a slug like a3f7k2m9 and the domain a3f7k2m9.example.com (the slug is prepended
#     to --domain because --slug is not given);
#   - /var/www/<slug> with the containers php, nginx, db (PostgreSQL 17), redis,
#     cron and certbot_renew; Laravel ^13.0; a Let's Encrypt certificate;
#   - credentials in /var/www/<slug>/.env and in the script output.
#
# Before running, change:
#   - example.com to your own domain; a wildcard record *.<domain> pointing
#     to the server is required, otherwise SSL cannot be obtained;
#   - admin@example.com to a real email for Let's Encrypt.
#
# Run on the server (from any folder):
#   bash /opt/laravel-deploy/examples/01-minimal-postgres.sh
# DEPLOY_DIR defaults to the laravel-deploy folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laravel-deploy bash 01-minimal-postgres.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --domain example.com \
  --db-type postgres \
  --ssl-email admin@example.com
