#!/bin/bash
set -euo pipefail

# ============================================================
# 07-filament-explicit-credentials.sh — Filament with explicit admin credentials
# ============================================================
# Scenario:
#   A site with Filament and MySQL; the administrator's name, email and password
#   are known in advance.
#
# Result:
#   - the panel https://backoffice.example.com/admin;
#   - login: admin@example.com / the password from --filament-password;
#   - the credentials are duplicated in /var/www/backoffice/.env (FILAMENT_ADMIN_*).
#
# Before running, change:
#   - the slug, domain and email;
#   - ChangeMe_Filament1 to your own password. Use the characters A-Za-z0-9@%_+-:
#     the value is written to .env without quotes, and docker compose reads this .env;
#   - the administrator name (--filament-name).
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/07-filament-explicit-credentials.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 07-filament-explicit-credentials.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug backoffice \
  --domain backoffice.example.com \
  --db-type mysql \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --ssl-email admin@example.com
