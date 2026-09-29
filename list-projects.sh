#!/bin/bash
#
# Скрипт для вывода списка всех развёрнутых проектов в /var/www
#

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

WWW_DIR="/var/www"

# Функция для вывода информации
info() {
    echo -e "${CYAN}[INFO]${NC}  $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC}  $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC}    $1"
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   error "Этот скрипт должен быть запущен с правами root (sudo)"
   exit 1
fi

# Заголовок
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Список развёрнутых проектов${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Проверка существования директории
if [[ ! -d "$WWW_DIR" ]]; then
    error "Директория ${WWW_DIR} не существует"
    exit 1
fi

# Счётчик проектов
PROJECT_COUNT=0
RUNNING_COUNT=0

# Сканируем директории в /var/www (исключая nginxproxy)
for PROJECT_DIR in "${WWW_DIR}"/*; do
    # Пропускаем если это не директория
    if [[ ! -d "$PROJECT_DIR" ]]; then
        continue
    fi
    
    # Получаем имя проекта (slug)
    SLUG=$(basename "$PROJECT_DIR")
    
    # Пропускаем nginxproxy
    if [[ "$SLUG" == "nginxproxy" ]]; then
        continue
    fi
    
    # Проверяем наличие docker-compose.yml
    if [[ ! -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        continue
    fi
    
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    
    # Получаем домен из .env
    DOMAIN="N/A"
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        DOMAIN=$(grep "^SITE_HOST=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    fi
    
    # Получаем порты из .env
    PORT_HTTP=$(grep "^SITE_PORT_HTTP=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    PORT_HTTPS=$(grep "^SITE_PORT_HTTPS=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    PORT_PHP=$(grep "^PHP_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    
    # Получаем тип БД
    DB_TYPE="N/A"
    if grep -q "^DB_POSTGRES_NAME=" "${PROJECT_DIR}/.env" 2>/dev/null; then
        DB_TYPE="PostgreSQL"
        DB_PORT=$(grep "^DB_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    elif grep -q "^DB_MYSQL_NAME=" "${PROJECT_DIR}/.env" 2>/dev/null; then
        DB_TYPE="MySQL"
        DB_PORT=$(grep "^DB_PORT=" "${PROJECT_DIR}/.env" 2>/dev/null | cut -d'=' -f2 || echo "N/A")
    else
        DB_PORT="N/A"
    fi
    
    # Проверяем статус контейнеров
    cd "$PROJECT_DIR" || continue
    
    TOTAL_CONTAINERS=$(docker compose ps -a --format "{{.Name}}" 2>/dev/null | wc -l)
    RUNNING_CONTAINERS=$(docker compose ps --format "{{.Name}}" --status running 2>/dev/null | wc -l)
    
    # Определяем статус проекта
    if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
        STATUS="${GREEN}RUNNING${NC} (${RUNNING_CONTAINERS}/${TOTAL_CONTAINERS})"
        RUNNING_COUNT=$((RUNNING_COUNT + 1))
    elif [[ $TOTAL_CONTAINERS -gt 0 ]]; then
        STATUS="${YELLOW}STOPPED${NC} (0/${TOTAL_CONTAINERS})"
    else
        STATUS="${RED}NO CONTAINERS${NC}"
    fi
    
    # Проверяем наличие SSL сертификата (он лежит в docker volume <slug>_ssl_certificates)
    SSL_STATUS="${RED}NO${NC}"
    SSL_VOLUME_DIR=$(docker volume inspect -f '{{.Mountpoint}}' "${SLUG}_ssl_certificates" 2>/dev/null || true)
    if [[ -n "$SSL_VOLUME_DIR" && -e "${SSL_VOLUME_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
        SSL_STATUS="${GREEN}YES${NC}"
    fi
    
    # Выводим информацию о проекте
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Проект:${NC}      ${SLUG}"
    echo -e "${CYAN}Домен:${NC}       ${DOMAIN}"
    echo -e "${CYAN}Статус:${NC}      ${STATUS}"
    echo -e "${CYAN}SSL:${NC}         ${SSL_STATUS}"
    echo -e "${CYAN}БД:${NC}          ${DB_TYPE} (порт: ${DB_PORT})"
    echo -e "${CYAN}Порты:${NC}       HTTP: ${PORT_HTTP}, HTTPS: ${PORT_HTTPS}, PHP: ${PORT_PHP}"
    echo -e "${CYAN}Путь:${NC}        ${PROJECT_DIR}"
    
    # Показываем основные контейнеры
    if [[ $TOTAL_CONTAINERS -gt 0 ]]; then
        echo -e "${CYAN}Контейнеры:${NC}"
        docker compose ps -a --format "  - {{.Name}}: {{.Status}}" 2>/dev/null | head -n 5
        if [[ $TOTAL_CONTAINERS -gt 5 ]]; then
            echo "  ... и ещё $((TOTAL_CONTAINERS - 5)) контейнеров"
        fi
    fi
    
    # Команды управления
    if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
        echo -e "${CYAN}Деактивировать:${NC} sudo bash deactivate.sh --slug ${SLUG}"
    else
        echo -e "${CYAN}Активировать:${NC}   sudo bash activate.sh --slug ${SLUG}"
    fi
    echo -e "${CYAN}Удалить:${NC}        sudo bash remove.sh --slug ${SLUG} --domain ${DOMAIN}"
    echo ""
done

# Итоговая статистика
echo -e "${BLUE}========================================${NC}"
echo -e "${CYAN}Всего проектов:${NC}    ${PROJECT_COUNT}"
echo -e "${CYAN}Запущено:${NC}         ${GREEN}${RUNNING_COUNT}${NC}"
echo -e "${CYAN}Остановлено:${NC}      ${YELLOW}$((PROJECT_COUNT - RUNNING_COUNT))${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Проверяем nginxproxy
if [[ -d "${WWW_DIR}/nginxproxy" ]]; then
    echo -e "${CYAN}Nginx Proxy:${NC}"
    cd "${WWW_DIR}/nginxproxy" || exit 0
    PROXY_STATUS=$(docker compose ps --format "{{.Status}}" 2>/dev/null | head -n 1 || echo "Not running")
    if [[ "$PROXY_STATUS" == *"Up"* ]]; then
        echo -e "  Статус: ${GREEN}RUNNING${NC}"
    else
        echo -e "  Статус: ${RED}STOPPED${NC}"
    fi
    
    # Показываем количество сайтов в nginxproxy
    SITES_COUNT=$(ls -1 "${WWW_DIR}/nginxproxy/sites"/*.conf 2>/dev/null | wc -l)
    echo -e "  Сайтов в конфигурации: ${SITES_COUNT}"
    echo ""
fi

exit 0
