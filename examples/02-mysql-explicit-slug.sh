#!/bin/bash
set -euo pipefail

# ============================================================
# 02-mysql-explicit-slug.sh — MySQL in a container, explicit slug
# ============================================================
# Scenario:
#   A regular site with MySQL and a known slug and domain.
#   The DB credentials, Redis password and ports are generated automatically.
#
# Result:
#   - project /var/www/shop, domain shop.example.com (with an explicit --slug
#     the domain is not changed);
#   - MySQL 8.0 in the shop_db container; Laravel's .env gets
#     DB_HOST=shop_db and DB_PORT=3306;
#   - an HTTPS certificate from Let's Encrypt.
#
# Before running, change:
#   - the slug shop and the domain shop.example.com (the A record must point to the server);
#   - admin@example.com to a real email.
#
# Run on the server (from any folder):
#   bash /opt/laravel-deploy/examples/02-mysql-explicit-slug.sh
# DEPLOY_DIR defaults to the laravel-deploy folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laravel-deploy bash 02-mysql-explicit-slug.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug shop \
  --domain shop.example.com \
  --db-type mysql \
  --ssl-email admin@example.com
