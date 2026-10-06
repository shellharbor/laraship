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
#   - HTTPS blocks are commented out; the application is available over HTTP
#     with HTTP APP_URL, and the ACME challenge remains reachable.
#
# Once DNS works, follow README -> "SSL not obtained": the checked procedure
# locks the project, requests the certificate, validates project/shared proxy
# TLS and updates APP_URL after successful application.
#
# Before running, change: the slug and domain.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/09-no-ssl.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 09-no-ssl.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug preview \
  --domain preview.example.com \
  --db-type postgres \
  --no-ssl
