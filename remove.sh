#!/bin/bash

# ============================================================
# remove.sh — полное удаление проекта
# ============================================================
# Использование:
#   sudo bash remove.sh --slug cp --domain cp.lentrade.pro
#
# Что делает скрипт:
#   1. Удаляет все записи из docker-compose.yml в nginxproxy
#   2. Удаляет конфиг сайта nginxproxy/sites/<slug>.conf
#   3. Применяет конфигурацию nginxproxy (docker compose up -d)
#   4. Останавливает контейнеры проекта (docker compose down)
#   5. Удаляет все volumes проекта
#   6. Удаляет network проекта
#   7. Перезагружает nginxproxy (docker restart nginxproxy)
#   8. Удаляет папку проекта
#
# Параметры:
#   --slug SLUG           Slug проекта (обязательно)
#   --domain DOMAIN       Домен проекта (обязательно)
#   --db-root-password P  Root-пароль нативной MySQL (нужен, чтобы удалить её БД и пользователя)
# ============================================================

set -euo pipefail

# ==================== Переменные ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
SLUG=""
DOMAIN=""
DB_ROOT_PASSWORD=""

# ==================== Цветной вывод ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ==================== Проверка root =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен быть запущен с правами root (sudo)"
    fi
}

# ==================== Парсинг аргументов ============
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)    SLUG="$2";    shift 2 ;;
            --domain)  DOMAIN="$2";  shift 2 ;;
            --db-root-password) DB_ROOT_PASSWORD="$2"; shift 2 ;;
            *) error "Неизвестный аргумент: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]]   && error "Не указан --slug"
    [[ -z "$DOMAIN" ]] && error "Не указан --domain"

    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Проект не найден: ${PROJECT_DIR}"
    fi
}

# ==================== Подтверждение удаления ========
confirm_deletion() {
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}                   ⚠️  ВНИМАНИЕ! ⚠️${NC}"
    echo -e "${RED}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}Вы собираетесь ПОЛНОСТЬЮ УДАЛИТЬ проект:${NC}"
    echo ""
    echo -e "  Slug:           ${RED}${SLUG}${NC}"
    echo -e "  Домен:          ${RED}${DOMAIN}${NC}"
    echo -e "  Путь:           ${RED}${PROJECT_DIR}${NC}"
    echo ""
    echo -e "${YELLOW}Будет удалено:${NC}"
    echo "  • Все контейнеры проекта"
    echo "  • Все volumes (включая данные БД)"
    echo "  • Network проекта"
    echo "  • Конфигурация из nginxproxy"
    echo "  • Backup архив (если существует)"
    echo "  • Папка проекта со всеми файлами"
    echo ""
    echo -e "${RED}⚠️  ЭТО ДЕЙСТВИЕ НЕОБРАТИМО! ⚠️${NC}"
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo ""
    
    # Запрашиваем подтверждение
    read -p "Введите 'yes' для подтверждения удаления: " CONFIRMATION
    
    if [[ "$CONFIRMATION" != "yes" ]]; then
        echo ""
        info "Удаление отменено пользователем"
        exit 0
    fi
    
    echo ""
    info "Подтверждение получено. Начинаю удаление..."
}

# ==================== Удаление конфига сайта ====
remove_from_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    # После deactivate.sh конфиг лежит как <slug>.conf.disabled
    if [[ ! -f "$SITE_CONF" && ! -f "${SITE_CONF}.disabled" ]]; then
        warn "Конфиг ${SITE_CONF} не найден, пропускаю."
        return
    fi

    info "Удаляю конфиг ${SLUG}.conf..."

    rm -f "$SITE_CONF" "${SITE_CONF}.disabled"
    
    if [[ $? -eq 0 ]]; then
        info "Конфиг ${SLUG}.conf удалён"
    else
        error "Не удалось удалить конфиг ${SLUG}.conf"
    fi
}

# ==================== Удаление из docker-compose.yml ====
remove_from_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "Файл docker-compose.yml не найден: ${COMPOSE_FILE}"
    fi
    
    info "Удаляю записи ${SLUG} из docker-compose.yml..."
    
    python3 - "${COMPOSE_FILE}" "${SLUG}" <<'PYEOF'
import sys
import re

def in_service(lines, idx, name):
    """Строка idx лежит внутри сервиса name: ближайший выше ключ с отступом 2 — это name"""
    for j in range(idx - 1, -1, -1):
        m = re.match(r'^  ([\w.-]+):', lines[j])
        if m:
            return m.group(1) == name
        if re.match(r'^[^\s#]', lines[j]):
            return False
    return False

compose_file = sys.argv[1]
slug = sys.argv[2]

def is_slug_item(line):
    """Точное совпадение элемента списка ("- lms", "# - lms", "- lms_ssl_certificates:/...") —
    подстрока задела бы и другие проекты (lms → lms2)"""
    s = line.strip().lstrip('#').strip()
    if s.startswith('-'):
        s = s[1:].strip()
    return s.split(':', 1)[0] in (slug, f"{slug}_ssl_certificates")

with open(compose_file, 'r') as f:
    content = f.read()

lines = content.splitlines()
result = []
i = 0

while i < len(lines):
    line = lines[i]
    
    # Удаляем сеть из x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        # Проверяем, используется ли inline-синтаксис networks: []
        if line.strip() == "networks: []":
            # Оставляем как есть - пустой массив
            result.append(line)
            i += 1
        else:
            result.append(line)
            i += 1
            # Собираем сети, пропуская нужную
            remaining_networks = []
            while i < len(lines) and lines[i].strip().startswith("-"):
                if not is_slug_item(lines[i]):
                    remaining_networks.append(lines[i])
                i += 1
            # Если не осталось сетей, заменяем на inline-синтаксис
            if not remaining_networks:
                # Удаляем предыдущую строку "networks:" и добавляем "networks: []"
                result[-1] = "  networks: []"
            else:
                result.extend(remaining_networks)
        continue
    
    # Удаляем volume из сервиса nginxproxy
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            if not is_slug_item(lines[i]):
                result.append(lines[i])
            i += 1
        continue
    
    # Удаляем network на верхнем уровне
    if re.match(r'^networks:\s*$', line):
        i += 1
        remaining_items = []
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это блок с нужным slug
            if lines[i].strip().startswith(f"{slug}:"):
                # Пропускаем весь блок сети (включая дочерние элементы)
                i += 1
                while i < len(lines) and lines[i].startswith('    '):
                    i += 1
            else:
                remaining_items.append(lines[i])
                i += 1
        # Если остались элементы, добавляем секцию networks:
        if remaining_items:
            result.append("networks:")
            result.extend(remaining_items)
        else:
            # Если не осталось элементов, добавляем пустой mapping
            result.append("networks: {}")
        continue
    
    # Удаляем volume на верхнем уровне
    if re.match(r'^volumes:\s*$', line):
        i += 1
        remaining_items = []
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это блок с нужным slug
            if lines[i].strip().startswith(f"{slug}_ssl_certificates:"):
                # Пропускаем весь блок volume (включая дочерние элементы)
                i += 1
                while i < len(lines) and lines[i].startswith('    '):
                    i += 1
            else:
                remaining_items.append(lines[i])
                i += 1
        # Если остались элементы, добавляем секцию volumes:
        if remaining_items:
            result.append("volumes:")
            result.extend(remaining_items)
        else:
            # Если не осталось элементов, добавляем пустой mapping
            result.append("volumes: {}")
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Записи {slug} удалены из docker-compose.yml")
PYEOF

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml успешно обновлён"
    else
        error "Не удалось обновить docker-compose.yml"
    fi
}

# ==================== Применение конфигурации nginxproxy ====
apply_proxy_config() {
    info "Применяю конфигурацию nginxproxy..."
    cd "${PROXY_DIR}" || error "Не удалось перейти в ${PROXY_DIR}"
    
    docker compose up -d
    
    if [[ $? -eq 0 ]]; then
        info "Конфигурация nginxproxy применена"
    else
        warn "Возникли проблемы при применении конфигурации nginxproxy"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Остановка контейнеров проекта =
stop_project_containers() {
    info "Останавливаю контейнеры проекта ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в ${PROJECT_DIR}"
    
    docker compose down
    
    if [[ $? -eq 0 ]]; then
        info "Контейнеры проекта ${SLUG} остановлены"
    else
        warn "Возникли проблемы при остановке контейнеров"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Удаление volumes проекта =======
remove_project_volumes() {
    info "Удаляю volumes проекта ${SLUG}..."
    
    # Получаем список volumes из docker-compose.yml проекта
    cd "${PROJECT_DIR}" || error "Не удалось перейти в ${PROJECT_DIR}"
    
    local VOLUMES=$(grep -E "^  ${SLUG}_" docker-compose.yml | sed 's/://g' | awk '{print $1}' || true)
    
    if [[ -z "$VOLUMES" ]]; then
        info "Volumes не найдены в docker-compose.yml"
    else
        for volume in $VOLUMES; do
            info "Удаляю volume: ${volume}"
            docker volume rm "${volume}" 2>/dev/null || warn "Volume ${volume} не найден или уже удалён"
        done
        info "Все volumes проекта удалены"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Удаление network проекта =======
remove_project_network() {
    info "Удаляю network проекта ${SLUG}..."
    
    docker network rm "${SLUG}" 2>/dev/null || warn "Network ${SLUG} не найден или уже удалён"
    
    info "Network проекта удалён"
}

# ==================== Перезагрузка nginxproxy ========
restart_nginxproxy() {
    info "Перезагружаю nginxproxy..."
    
    docker restart nginxproxy
    
    if [[ $? -eq 0 ]]; then
        info "nginxproxy успешно перезагружен"
    else
        warn "Возникли проблемы при перезагрузке nginxproxy"
    fi
}

# ==================== Удаление нативной БД ===========
remove_native_database() {
    # Проверяем наличие .env файла проекта
    local ENV_FILE="${PROJECT_DIR}/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        info "Файл .env не найден, пропускаю проверку нативной БД"
        return
    fi
    
    # Читаем переменные из .env безопасно (избегаем проблем со спецсимволами)
    set -a
    while IFS='=' read -r key value; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Удаляем возможные пробелы вокруг ключа
        key=$(echo "$key" | xargs)
        # Проверяем что ключ не пустой после обработки
        [[ -z "$key" ]] && continue
        # Экспортируем переменную
        export "$key=$value"
    done < "$ENV_FILE"
    set +a
    
    # Проект без БД (HTML)
    if [[ -z "${DB_POSTGRES_NAME:-}" && -z "${DB_MYSQL_NAME:-}" ]]; then
        info "Проект без БД, пропускаю удаление нативной БД"
        return
    fi

    # Проверяем, используется ли нативная БД
    # Способ 1: флаг DB_NATIVE (его пишут все deploy-скрипты)
    local IS_NATIVE=false
    if [[ "${DB_NATIVE:-}" == "true" ]]; then
        IS_NATIVE=true
    fi

    # Способ 2: флага нет (старые проекты) — смотрим, есть ли сервис БД в docker-compose.yml.
    # deploy переименовывает сервис в "db", поэтому ищем db, db_postgres и db_mysql
    if [[ -z "${DB_NATIVE:-}" && -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        if ! grep -qE '^  db(_postgres|_mysql)?:' "${PROJECT_DIR}/docker-compose.yml" 2>/dev/null; then
            IS_NATIVE=true
            info "Обнаружена нативная БД (отсутствует db контейнер в docker-compose.yml)"
        fi
    fi
    
    if [[ "$IS_NATIVE" != true ]]; then
        info "Проект использует контейнерную БД, пропускаю удаление нативной БД"
        return
    fi
    
    info "Обнаружена нативная база данных, удаляю..."
    
    # Определяем тип БД по наличию переменных
    if [[ -n "${DB_POSTGRES_NAME:-}" ]]; then
        # Удаляем PostgreSQL базу данных и пользователя
        info "Удаляю PostgreSQL базу данных: ${DB_POSTGRES_NAME}"
        
        if command -v psql &> /dev/null; then
            # Отключаем все активные соединения
            sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_POSTGRES_NAME}';" 2>/dev/null || true
            
            # Удаляем базу данных
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${DB_POSTGRES_NAME}\";" 2>/dev/null && \
                info "База данных ${DB_POSTGRES_NAME} удалена" || \
                warn "Не удалось удалить базу данных ${DB_POSTGRES_NAME}"
            
            # Удаляем пользователя
            sudo -u postgres psql -c "DROP USER IF EXISTS \"${DB_POSTGRES_USER:-}\";" 2>/dev/null && \
                info "Пользователь ${DB_POSTGRES_USER:-} удалён" || \
                warn "Не удалось удалить пользователя ${DB_POSTGRES_USER:-}"
        else
            warn "PostgreSQL не установлен, пропускаю удаление БД"
        fi
        
    elif [[ -n "${DB_MYSQL_NAME:-}" ]]; then
        # Удаляем MySQL базу данных и пользователя
        info "Удаляю MySQL базу данных: ${DB_MYSQL_NAME}"

        if command -v mysql &> /dev/null; then
            # Root-пароль системной MySQL в .env не хранится — его передают через --db-root-password
            local ROOT_PW="${DB_ROOT_PASSWORD:-}"
            if [[ -n "$ROOT_PW" ]]; then
                # Удаляем базу данных
                mysql -u root -p"${ROOT_PW}" -e "DROP DATABASE IF EXISTS \`${DB_MYSQL_NAME}\`;" 2>/dev/null && \
                    info "База данных ${DB_MYSQL_NAME} удалена" || \
                    warn "Не удалось удалить базу данных ${DB_MYSQL_NAME}"

                # Удаляем пользователя (deploy создаёт 'user'@'%', старые версии — 'user'@'localhost')
                mysql -u root -p"${ROOT_PW}" -e "DROP USER IF EXISTS '${DB_MYSQL_USER:-}'@'%', '${DB_MYSQL_USER:-}'@'localhost';" 2>/dev/null && \
                    info "Пользователь ${DB_MYSQL_USER:-} удалён" || \
                    warn "Не удалось удалить пользователя ${DB_MYSQL_USER:-}"

                mysql -u root -p"${ROOT_PW}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            else
                warn "Root-пароль MySQL не указан (--db-root-password), БД не удалена. Удалите вручную:"
                warn "  DROP DATABASE \`${DB_MYSQL_NAME}\`; DROP USER '${DB_MYSQL_USER:-}'@'%';"
            fi
        else
            warn "MySQL не установлен, пропускаю удаление БД"
        fi
    fi
}

# ==================== Удаление backup архива =========
remove_backup_archive() {
    # Проверяем наличие .env файла проекта
    local ENV_FILE="${PROJECT_DIR}/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        info "Файл .env не найден, пропускаю проверку backup архива"
        return
    fi
    
    # Читаем путь к backup архиву из .env
    local BACKUP_ARCHIVE_PATH=$(grep "^BACKUP_ARCHIVE_PATH=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    
    if [[ -z "$BACKUP_ARCHIVE_PATH" ]]; then
        info "Путь к backup архиву не найден в .env, пропускаю удаление"
        return
    fi
    
    # Проверяем существование архива и удаляем его
    if [[ -f "$BACKUP_ARCHIVE_PATH" ]]; then
        info "Удаляю backup архив: ${BACKUP_ARCHIVE_PATH}"
        rm -f "$BACKUP_ARCHIVE_PATH"
        
        if [[ $? -eq 0 ]]; then
            info "Backup архив успешно удалён"
        else
            warn "Не удалось удалить backup архив: ${BACKUP_ARCHIVE_PATH}"
        fi
    else
        info "Backup архив не найден по пути: ${BACKUP_ARCHIVE_PATH}"
    fi
}

# ==================== Удаление папки проекта =========
remove_project_directory() {
    info "Удаляю папку проекта ${PROJECT_DIR}..."
    
    rm -rf "${PROJECT_DIR}"
    
    if [[ $? -eq 0 ]]; then
        info "Папка проекта удалена"
    else
        error "Не удалось удалить папку проекта"
    fi
}

# ==================== Вывод итоговой информации =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Удаление проекта завершено!"
    echo "============================================================"
    echo ""
    echo "ПРОЕКТ: ${SLUG}"
    echo "  Домен:          ${DOMAIN}"
    echo "  Статус:         ПОЛНОСТЬЮ УДАЛЁН"
    echo ""
    echo "Что было удалено:"
    echo "  ✓ Конфигурация nginxproxy/sites/${SLUG}.conf"
    echo "  ✓ Записи из nginxproxy/docker-compose.yml"
    echo "  ✓ Контейнеры проекта остановлены"
    echo "  ✓ Все volumes проекта удалены"
    echo "  ✓ Network проекта удалён"
    echo "  ✓ Backup архив (если существовал)"
    echo "  ✓ Папка проекта ${PROJECT_DIR} удалена"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    
    # Запрашиваем подтверждение удаления
    confirm_deletion
    
    remove_from_docker_compose
    remove_from_nginx_conf
    apply_proxy_config
    stop_project_containers
    remove_project_volumes
    remove_project_network
    restart_nginxproxy
    remove_native_database
    remove_backup_archive
    remove_project_directory
    
    print_summary
}

main "$@"
