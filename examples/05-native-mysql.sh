#!/bin/bash
set -euo pipefail

# ============================================================
# 05-native-mysql.sh — MySQL на хосте (--db-native)
# ============================================================
# Сценарий:
#   БД сайта должна жить в системной MySQL сервера.
#
# Что получится:
#   - контейнера db нет; в системной MySQL созданы БД и пользователь
#     '<user>'@'%' (имена и пароль сгенерированы) с GRANT ALL на эту БД;
#   - в .env Laravel записаны DB_HOST=172.17.0.1 и DB_PORT=3306.
#
# Важно:
#   - --db-root-password обязателен. Он нужен для создания БД и НИГДЕ
#     не сохраняется. При удалении проекта передайте его снова:
#       sudo bash /opt/laravel-deploy/remove.sh --slug wiki --domain wiki.example.com --db-root-password '...'
#     Без него remove.sh только напечатает SQL для ручного удаления;
#   - строка "Root Password" в итоговом выводе и DB_MYSQL_PASSWORD_ROOT
#     в .env — случайное значение, а НЕ root-пароль системной MySQL;
#   - в Ubuntu по умолчанию bind-address = 127.0.0.1
#     (/etc/mysql/mysql.conf.d/mysqld.cnf). Чтобы контейнеры могли
#     подключиться, MySQL должна слушать адрес, доступный из docker
#     (например, 172.17.0.1 или 0.0.0.0 плюс фаервол).
#
# Перед запуском поменяйте:
#   - slug, домен и email;
#   - ChangeMe_MysqlRoot1 на настоящий root-пароль MySQL сервера;
#   - --port-mysql, если MySQL слушает не 3306 (флаг меняет только
#     DB_PORT в Laravel).
#
# Запуск на сервере (из любой папки):
#   bash /opt/laravel-deploy/examples/05-native-mysql.sh
# DEPLOY_DIR по умолчанию — папка laravel-deploy, в которой лежит этот пример
# (deploy-laravel.sh, laravel/, nginxproxy/). Переопределение:
#   DEPLOY_DIR=/srv/laravel-deploy bash 05-native-mysql.sh
# (root-пароль попадёт в историю shell; при необходимости очистите её)
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
