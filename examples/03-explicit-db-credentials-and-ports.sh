#!/bin/bash
set -euo pipefail

# ============================================================
# 03-explicit-db-credentials-and-ports.sh — явные учётные данные БД и порты
# ============================================================
# Сценарий:
#   Нужны предсказуемые имя БД, пользователь, пароли и порты хоста,
#   например для внешнего мониторинга или SSH-туннеля к БД.
#
# Что получится:
#   - БД PostgreSQL crm_db с пользователем crm_user и заданным паролем;
#   - порты хоста: HTTP 8150, HTTPS 4150, PHP-FPM 9150 (только 127.0.0.1),
#     Redis 6550, PostgreSQL 5550. Явно заданные порты скрипт НЕ проверяет
#     на занятость;
#   - Laravel подключается к crm_db:5432 (внутренний порт), а с хоста БД
#     доступна на 127.0.0.1:5550.
#
# Перед запуском поменяйте:
#   - slug, домен и email;
#   - все пароли ChangeMe_* на свои. Используйте только символы
#     A-Za-z0-9@%_+-: значения пишутся в .env без кавычек;
#   - порты, если они уже заняты (sudo ss -tlnp).
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/03-explicit-db-credentials-and-ports.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 03-explicit-db-credentials-and-ports.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug crm \
  --domain crm.example.com \
  --db-type postgres \
  --db-postgres-name crm_db \
  --db-postgres-user crm_user \
  --db-postgres-password ChangeMe_CrmDb1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8150 \
  --port-https 4150 \
  --port-php 9150 \
  --port-redis 6550 \
  --port-postgres 5550 \
  --ssl-email admin@example.com
