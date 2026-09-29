#!/bin/bash
set -euo pipefail

# ============================================================
# 07-filament-explicit-credentials.sh — Filament с заданными данными администратора
# ============================================================
# Сценарий:
#   Сайт с Filament и MySQL; имя, email и пароль администратора
#   известны заранее.
#
# Что получится:
#   - панель https://backoffice.example.com/admin;
#   - вход: admin@example.com / пароль из --filament-password;
#   - данные продублированы в /var/www/backoffice/.env (FILAMENT_ADMIN_*).
#
# Перед запуском поменяйте:
#   - slug, домен и email;
#   - ChangeMe_Filament1 на свой пароль. Используйте символы A-Za-z0-9@%_+-:
#     значение пишется в .env без кавычек, а этот .env читает docker compose;
#   - имя администратора (--filament-name).
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/07-filament-explicit-credentials.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 07-filament-explicit-credentials.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug backoffice \
  --domain backoffice.example.com \
  --db-type mysql \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --ssl-email admin@example.com
