#!/bin/bash
set -euo pipefail

# ============================================================
# 10-production-full.sh — production: всё явно, Filament, endpoint, backup
# ============================================================
# Сценарий:
#   Боевой сайт, где все параметры воспроизводимы, а данные проекта
#   отправляются во внешнюю систему учёта.
#
# Что получится:
#   - https://app.example.com на Laravel ^13.0 (версия зафиксирована явно)
#     с PostgreSQL в контейнере app_db (БД app_prod);
#   - фиксированные порты хоста: 8200/4200/9200/6600/5600;
#   - панель Filament https://app.example.com/admin;
#   - JSON с данными проекта, включая пароли, отправлен PUT-запросом на
#     https://api.example.com/deployments (пример тела: endpoint-payload.json);
#   - архив /tmp/app_<YYYYmmdd_HHMMSS>.zip; путь дописан в .env как
#     BACKUP_ARCHIVE_PATH. Данных БД в архиве нет, это только папка проекта.
#
# После развёртывания вручную:
#   - в /var/www/app/public_html/.env выставить APP_ENV=production и
#     APP_DEBUG=false, затем выполнить docker compose run --rm artisan config:cache.
#     Для Filament в production модель User должна реализовать
#     FilamentUser::canAccessPanel();
#   - закрыть фаерволом всё, кроме 80/443: порты 8200/4200/6600/5600
#     опубликованы на всех интерфейсах (PHP-FPM 9200 — только на 127.0.0.1),
#     а Docker обходит ufw;
#   - chmod 600 /var/www/app/.env.
#
# --create-dhparam сюда не добавлен: в текущем шаблоне он не включает
# ssl_dhparam (см. README → «Известные ограничения»).
#
# Перед запуском поменяйте:
#   - slug, домен, оба email и URL endpoint;
#   - все пароли ChangeMe_* (символы A-Za-z0-9@%_+-; в JSON они уходят
#     без экранирования);
#   - порты, если они заняты;
#   - проверьте совместимость Filament 5 с выбранной версией Laravel.
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/10-production-full.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 10-production-full.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug app \
  --domain app.example.com \
  --laravel-version 13.0 \
  --db-type postgres \
  --db-postgres-name app_prod \
  --db-postgres-user app_prod \
  --db-postgres-password ChangeMe_PgProd1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8200 \
  --port-https 4200 \
  --port-php 9200 \
  --port-redis 6600 \
  --port-postgres 5600 \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --endpoint https://api.example.com/deployments \
  --create-backup \
  --ssl-email admin@example.com
