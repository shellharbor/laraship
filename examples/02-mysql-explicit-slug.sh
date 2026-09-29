#!/bin/bash
set -euo pipefail

# ============================================================
# 02-mysql-explicit-slug.sh — MySQL в контейнере, явный slug
# ============================================================
# Сценарий:
#   Обычный сайт с MySQL и заранее известными slug и доменом.
#   Учётные данные БД, пароль Redis и порты генерируются автоматически.
#
# Что получится:
#   - проект /var/www/shop, домен shop.example.com (при явном --slug
#     домен не меняется);
#   - MySQL 8.0 в контейнере shop_db; в .env Laravel записаны
#     DB_HOST=shop_db и DB_PORT=3306;
#   - HTTPS-сертификат Let's Encrypt.
#
# Перед запуском поменяйте:
#   - slug shop и домен shop.example.com (A-запись должна указывать на сервер);
#   - admin@example.com на реальный email.
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/02-mysql-explicit-slug.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 02-mysql-explicit-slug.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug shop \
  --domain shop.example.com \
  --db-type mysql \
  --ssl-email admin@example.com
