#!/bin/bash
set -euo pipefail

# ============================================================
# 01-minimal-postgres.sh — минимальное развёртывание с PostgreSQL
# ============================================================
# Сценарий:
#   Быстро поднять Laravel с PostgreSQL в контейнере. Slug, порты,
#   имена БД и все пароли генерируются автоматически.
#
# Что получится:
#   - slug вида a3f7k2m9 и домен a3f7k2m9.example.com (slug добавляется
#     к --domain, потому что --slug не указан);
#   - /var/www/<slug> с контейнерами php, nginx, db (PostgreSQL 17), redis,
#     cron и certbot_renew; Laravel ^13.0; сертификат Let's Encrypt;
#   - учётные данные в /var/www/<slug>/.env и в выводе скрипта.
#
# Перед запуском поменяйте:
#   - example.com на свой домен; нужна wildcard-запись *.<домен>,
#     указывающая на сервер, иначе SSL не получить;
#   - admin@example.com на реальный email для Let's Encrypt.
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/01-minimal-postgres.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 01-minimal-postgres.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --domain example.com \
  --db-type postgres \
  --ssl-email admin@example.com
