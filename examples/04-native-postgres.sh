#!/bin/bash
set -euo pipefail

# ============================================================
# 04-native-postgres.sh — PostgreSQL на хосте (--db-native)
# ============================================================
# Сценарий:
#   На сервере уже работает системный PostgreSQL, и БД сайта должна
#   жить в нём, а не в отдельном контейнере.
#
# Что получится:
#   - контейнера db нет; пользователь и БД (имена и пароль сгенерированы)
#     созданы через `sudo -u postgres psql`;
#   - в .env Laravel записаны DB_HOST=172.17.0.1 и DB_PORT=5432;
#   - остальное как обычно: nginx, php, redis, SSL.
#
# До запуска администратор должен настроить PostgreSQL (скрипт этого не делает):
#   - PostgreSQL установлен и запущен (systemctl status postgresql);
#   - listen_addresses включает 172.17.0.1 или '*';
#   - pg_hba.conf пускает docker-подсети, например:
#       host  all  all  172.16.0.0/12  scram-sha-256
#     затем выполнить systemctl reload postgresql;
#   - фаервол пропускает docker-подсети на порт 5432.
#
# Перед запуском поменяйте:
#   - slug, домен и email;
#   - если PostgreSQL слушает не 5432, добавьте --port-postgres <порт>.
#     Флаг меняет только DB_PORT в Laravel; БД всё равно создаётся
#     через подключение psql по умолчанию.
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/04-native-postgres.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 04-native-postgres.sh
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-laravel.sh" \
  --slug blog \
  --domain blog.example.com \
  --db-type postgres \
  --db-native \
  --ssl-email admin@example.com
