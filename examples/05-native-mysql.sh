#!/bin/bash
set -euo pipefail

# ============================================================
# 05-native-mysql.sh — MySQL on the host (--db-native)
# ============================================================
# Scenario:
#   The site's DB should live in the server's system MySQL.
#
# Result:
#   - there is no db container; a DB and a user '<user>'@'%' (names and password
#     are generated) with GRANT ALL on that DB are created in the system MySQL;
#   - Laravel's .env gets DB_HOST=<the Docker host, normally 172.17.0.1> and DB_PORT=3306.
#
# Important:
#   - --db-root-password is required. It is needed to create the DB and is NEVER
#     stored. When removing the project, pass it again:
#       sudo bash /opt/laraship/remove.sh --slug wiki --domain wiki.example.com --db-root-password '...'
#     Without it, remove.sh only prints the SQL for manual removal;
#   - the "Root Password" line in the final output and DB_MYSQL_PASSWORD_ROOT
#     in .env are a random value, NOT the system MySQL root password;
#   - on Ubuntu, bind-address = 127.0.0.1 by default
#     (/etc/mysql/mysql.conf.d/mysqld.cnf). For the containers to be able to
#     connect, MySQL must listen on an address reachable from docker
#     (for example 172.17.0.1, or 0.0.0.0 plus a firewall).
#
# Before running, change:
#   - the slug, domain and email;
#   - ChangeMe_MysqlRoot1 to the real MySQL root password of the server;
#   - --port-mysql, if MySQL does not listen on 3306 (the flag only changes
#     DB_PORT in Laravel).
#
# Run on the server (from any folder):
#   bash /opt/laraship/examples/05-native-mysql.sh
# DEPLOY_DIR defaults to the laraship folder that contains this example
# (deploy-laravel.sh, laravel/, nginxproxy/). To override:
#   DEPLOY_DIR=/srv/laraship bash 05-native-mysql.sh
# (the root password ends up in the shell history; clear it if necessary)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug wiki \
  --domain wiki.example.com \
  --db-type mysql \
  --db-native \
  --db-root-password ChangeMe_MysqlRoot1 \
  --port-mysql 3306 \
  --ssl-email admin@example.com
