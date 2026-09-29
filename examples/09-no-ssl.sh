#!/bin/bash
set -euo pipefail

# ============================================================
# 09-no-ssl.sh — deployment without obtaining a certificate (--no-ssl)
# ============================================================
# Scenario:
#   DNS has not been switched to the server yet, but the project and DB need to be
#   prepared in advance. The certificate is obtained later, manually. --ssl-email is not needed.
#
# Result:
#   - the project, containers, Laravel and DB are ready;
#   - the HTTPS blocks in _site.conf and nginxproxy/sites/preview.conf are
#     commented out. The HTTP block serves only /.well-known/acme-challenge/,
#     so THE SITE IS UNAVAILABLE until a certificate is obtained.
#
# Once DNS works (run on the server):
#   cd /var/www/preview
#   docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
#     -d preview.example.com --email admin@example.com --agree-tos --non-interactive
#   sed -i '/^#server {/,/^#}/ s/^#//' .config/nginx/_site.conf /var/www/nginxproxy/sites/preview.conf
#   docker compose exec nginx nginx -t && docker compose restart nginx
#   cd /var/www/nginxproxy && docker compose restart
#
# Before running, change: the slug and domain.
#
# Run on the server (from any folder):
#   bash /opt/laravel-deploy/examples/09-no-ssl.sh
# DEPLOY_DIR defaults to the laravel-deploy folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laravel-deploy bash 09-no-ssl.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug preview \
  --domain preview.example.com \
  --db-type postgres \
  --no-ssl
