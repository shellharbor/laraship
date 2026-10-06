#!/bin/bash
set -euo pipefail

# ============================================================
# 08-basic-auth.sh — closed environment with HTTP Basic Auth
# ============================================================
# Scenario:
#   A staging or demo environment that must not be visible to outsiders.
#
# Result:
#   - the file /var/www/staging/.config/nginx/.htpasswd (created via httpd:alpine)
#     and the mount in docker-compose.yml uncommented;
#   - auth_basic directives in location / of the project nginx HTTPS block;
#   - AUTH_USER and AUTH_PASSWORD in /var/www/staging/.env.
#
# Limitation:
#   Basic Auth is enabled only in location /. A direct request to /index.php
#   (including /index.php/<route>) is handled by the PHP location without
#   auth_basic and bypasses the protection. Do not rely on Basic Auth as the
#   only protection.
#
# Before running, change:
#   - the slug, domain and email;
#   - the login and password (without --auth-user/--auth-password they are generated).
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/08-basic-auth.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 08-basic-auth.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug staging \
  --domain staging.example.com \
  --db-type postgres \
  --enable-basic-auth \
  --auth-user staging \
  --auth-password ChangeMe_Staging1 \
  --ssl-email admin@example.com
