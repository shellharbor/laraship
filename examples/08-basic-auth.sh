#!/bin/bash
set -euo pipefail

# ============================================================
# 08-basic-auth.sh — закрытый стенд с HTTP Basic Auth
# ============================================================
# Сценарий:
#   Staging или демо-стенд, который не должен быть виден посторонним.
#
# Что получится:
#   - файл /var/www/staging/.config/nginx/.htpasswd (создаётся через httpd:alpine)
#     и раскомментированное монтирование в docker-compose.yml;
#   - директивы auth_basic в location / HTTPS-блока nginx проекта;
#   - AUTH_USER и AUTH_PASSWORD в /var/www/staging/.env.
#
# Ограничение:
#   Basic Auth включается только в location /. Прямой запрос к /index.php
#   (в том числе /index.php/<маршрут>) обрабатывается PHP-location без
#   auth_basic и обходит защиту. Не полагайтесь на Basic Auth как на
#   единственную защиту.
#
# Перед запуском поменяйте:
#   - slug, домен и email;
#   - логин и пароль (без флагов --auth-user/--auth-password они сгенерируются).
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/08-basic-auth.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 08-basic-auth.sh
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
