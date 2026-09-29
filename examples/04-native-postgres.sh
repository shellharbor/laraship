#!/bin/bash
set -euo pipefail

# ============================================================
# 04-native-postgres.sh — PostgreSQL on the host (--db-native)
# ============================================================
# Scenario:
#   The server already runs a system PostgreSQL, and the site's DB should
#   live in it rather than in a separate container.
#
# Result:
#   - there is no db container; the user and DB (names and password are generated)
#     are created via `sudo -u postgres psql`;
#   - Laravel's .env gets DB_HOST=172.17.0.1 and DB_PORT=5432;
#   - everything else as usual: nginx, php, redis, SSL.
#
# Before running, the administrator must configure PostgreSQL (the script does not do this):
#   - PostgreSQL is installed and running (systemctl status postgresql);
#   - listen_addresses includes 172.17.0.1 or '*';
#   - pg_hba.conf allows the docker subnets, for example:
#       host  all  all  172.16.0.0/12  scram-sha-256
#     then run systemctl reload postgresql;
#   - the firewall allows the docker subnets to port 5432.
#
# Before running, change:
#   - the slug, domain and email;
#   - if PostgreSQL does not listen on 5432, add --port-postgres <port>.
#     The flag only changes DB_PORT in Laravel; the DB is still created
#     through the default psql connection.
#
# Run on the server (from any folder):
#   bash /opt/laravel-deploy/examples/04-native-postgres.sh
# DEPLOY_DIR defaults to the laravel-deploy folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laravel-deploy bash 04-native-postgres.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug blog \
  --domain blog.example.com \
  --db-type postgres \
  --db-native \
  --ssl-email admin@example.com
