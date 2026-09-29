#!/bin/bash
set -euo pipefail

# ============================================================
# 09-no-ssl.sh — развёртывание без получения сертификата (--no-ssl)
# ============================================================
# Сценарий:
#   DNS ещё не переключён на сервер, а проект и БД нужно подготовить
#   заранее. Сертификат получают позже вручную. --ssl-email не нужен.
#
# Что получится:
#   - проект, контейнеры, Laravel и БД готовы;
#   - HTTPS-блоки в _site.conf и nginxproxy/sites/preview.conf
#     закомментированы. HTTP-блок отдаёт только /.well-known/acme-challenge/,
#     поэтому САЙТ НЕДОСТУПЕН, пока не будет получен сертификат.
#
# Когда DNS заработает (выполнять на сервере):
#   cd /var/www/preview
#   docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
#     -d preview.example.com --email admin@example.com --agree-tos --non-interactive
#   sed -i '/^#server {/,/^#}/ s/^#//' .config/nginx/_site.conf /var/www/nginxproxy/sites/preview.conf
#   docker compose exec nginx nginx -t && docker compose restart nginx
#   cd /var/www/nginxproxy && docker compose restart
#
# Перед запуском поменяйте: slug и домен.
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/09-no-ssl.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 09-no-ssl.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug preview \
  --domain preview.example.com \
  --db-type postgres \
  --no-ssl
