#!/bin/bash
set -euo pipefail

# ============================================================
# 15-preset.sh — a preset and a dry run (--preset, --dry-run)
# ============================================================
# Scenario:
#   An API backend: the `api` preset stands for Redis, Laravel Horizon, ports on 127.0.0.1 only and
#   16M uploads. First look at what the command would do (--dry-run: nothing is changed, no root
#   needed), then deploy it.
#
# Result:
#   The same project as with the equivalent flags. A flag can still override a value of the preset,
#   for example: --preset api --php-upload-max 256M
#
# List the presets (no root needed):
#   bash /opt/laraship/deploy-laravel.sh --list-presets
#
# Before running, change: the slug, domain and email.
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/15-preset.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 15-preset.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

ARGS=(
  --slug api
  --domain api.example.com
  --db-type postgres
  --preset api
  --ssl-email admin@example.com
)

echo "== Dry run: the effective settings =="
bash "$DEPLOY_DIR/deploy-laravel.sh" --dry-run "${ARGS[@]}"

echo
echo "== Deploying =="
sudo bash "$DEPLOY_DIR/deploy-laravel.sh" "${ARGS[@]}"
