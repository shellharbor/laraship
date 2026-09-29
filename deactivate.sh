#!/bin/bash

# ============================================================
# deactivate.sh — деактивация/выключение проекта без удаления
# ============================================================
# Использование:
#   sudo bash deactivate.sh --slug cp
#
# Что делает скрипт:
#   1. Останавливает контейнеры проекта (docker compose down)
#   2. Отключает конфиг сайта: nginxproxy/sites/<slug>.conf → <slug>.conf.disabled
#   3. Комментирует записи slug в nginxproxy/docker-compose.yml
#   4. Перезагружает nginxproxy (docker restart nginxproxy)
#
# Параметры:
#   --slug SLUG           Slug проекта (обязательно)
# ============================================================

set -euo pipefail

# ==================== Переменные ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
SLUG=""

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
            *) error "Неизвестный аргумент: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]] && error "Не указан --slug"

    PROJECT_DIR="${WWW_DIR}/${SLUG}"
    if [[ ! -d "$PROJECT_DIR" ]]; then
        error "Проект не найден: ${PROJECT_DIR}"
    fi
}

# ==================== Остановка контейнеров проекта =
stop_project_containers() {
    info "Останавливаю контейнеры проекта ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в ${PROJECT_DIR}"
    
    if docker compose down; then
        info "Контейнеры проекта ${SLUG} остановлены"
    else
        warn "Возникли проблемы при остановке контейнеров"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Отключение конфига сайта в nginxproxy ====
# Контейнеры проекта остановлены: если оставить sites/<slug>.conf, nginx прокси
# не разрешит upstream <slug>_nginx, не запустится — и перестанут работать все сайты
disable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "$SITE_CONF" ]]; then
        mv "$SITE_CONF" "${SITE_CONF}.disabled"
        info "Конфиг ${SLUG}.conf отключён (переименован в ${SLUG}.conf.disabled)"
    else
        warn "Конфиг ${SITE_CONF} не найден, пропускаю."
    fi
}

# ==================== Комментирование в docker-compose.yml ====
comment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "Файл docker-compose.yml не найден: ${COMPOSE_FILE}"
    fi
    
    info "Комментирую записи ${SLUG} в docker-compose.yml..."
    
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
    
    # Комментируем сеть из x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        result.append(line)
        i += 1
        # Обрабатываем список сетей
        while i < len(lines) and lines[i].strip().startswith("-"):
            if is_slug_item(lines[i]):
                # Комментируем строку с нужным slug, сохраняя отступ
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Комментируем volume из сервиса nginxproxy
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            if is_slug_item(lines[i]):
                # Комментируем строку с нужным slug, сохраняя отступ
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Комментируем network на верхнем уровне
    if re.match(r'^networks:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это блок с нужным slug
            if lines[i].strip().startswith(f"{slug}:"):
                # Комментируем заголовок блока, сохраняя отступ
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
                i += 1
                # Комментируем все дочерние элементы
                while i < len(lines) and lines[i].startswith('    '):
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    result.append(" " * indent + "# " + lines[i].strip())
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    # Комментируем volume на верхнем уровне
    if re.match(r'^volumes:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это блок с нужным slug
            if lines[i].strip().startswith(f"{slug}_ssl_certificates:"):
                # Комментируем заголовок блока, сохраняя отступ
                indent = len(lines[i]) - len(lines[i].lstrip())
                result.append(" " * indent + "# " + lines[i].strip())
                i += 1
                # Комментируем все дочерние элементы
                while i < len(lines) and lines[i].startswith('    '):
                    indent = len(lines[i]) - len(lines[i].lstrip())
                    result.append(" " * indent + "# " + lines[i].strip())
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Записи {slug} закомментированы в docker-compose.yml")
PYEOF

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml успешно обновлён"
    else
        error "Не удалось обновить docker-compose.yml"
    fi
}

# ==================== Перезагрузка nginxproxy ========
restart_nginxproxy() {
    info "Перезагружаю nginxproxy..."
    
    if docker restart nginxproxy; then
        info "nginxproxy успешно перезагружен"
    else
        warn "Возникли проблемы при перезагрузке nginxproxy"
    fi
}

# ==================== Вывод итоговой информации =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Деактивация проекта завершена!"
    echo "============================================================"
    echo ""
    echo "ПРОЕКТ: ${SLUG}"
    echo "  Статус:         ДЕАКТИВИРОВАН"
    echo ""
    echo "Что было сделано:"
    echo "  ✓ Контейнеры проекта остановлены (docker compose down)"
    echo "  ✓ Конфиг nginxproxy/sites/${SLUG}.conf отключён (.disabled)"
    echo "  ✓ Записи закомментированы в nginxproxy/docker-compose.yml"
    echo "  ✓ nginxproxy перезагружен"
    echo ""
    echo "Для активации проекта используйте:"
    echo "  sudo bash activate.sh --slug ${SLUG}"
    echo ""
    echo "Для полного удаления проекта используйте:"
    echo "  sudo bash remove.sh --slug ${SLUG} --domain <domain>"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    
    info "Начинаю деактивацию проекта ${SLUG}..."
    echo ""
    
    stop_project_containers
    disable_site_conf
    comment_in_docker_compose
    restart_nginxproxy
    
    print_summary
}

main "$@"
