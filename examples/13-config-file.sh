#!/bin/bash
set -euo pipefail

# ============================================================
# 13-config-file.sh — the whole deployment described in a file (--config)
# ============================================================
# Scenario:
#   A repeatable deployment: every setting lives in one KEY=VALUE file that can be kept in a
#   private repository, reviewed and reused. Flags on the command line still win over the file,
#   so a single value can be changed without editing it.
#
# Result:
#   The same project as with the equivalent flags (see deploy.config.example for the settings).
#
# Before running (on the server):
#   cp /opt/laraship/examples/deploy.config.example /root/shop.conf
#   chmod 600 /root/shop.conf      # the file holds passwords
#   nano /root/shop.conf           # domain, email, passwords
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/13-config-file.sh
#   CONFIG=/root/other.conf bash /opt/laraship/examples/13-config-file.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 13-config-file.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG="${CONFIG:-/root/shop.conf}"

# Flags after --config override the file, for example: --slug shop-staging --no-ssl
sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --config "$CONFIG"
