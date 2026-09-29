#!/bin/bash

# ============================================================
# activate.sh — активация/включение деактивированного проекта
# ============================================================
# Использование:
#   sudo bash activate.sh --slug cp
#
# Что делает скрипт:
#   1. Запускает контейнеры проекта (docker compose up -d --build)
#   2. Возвращает конфиг сайта: nginxproxy/sites/<slug>.conf.disabled → <slug>.conf
#   3. Раскомментирует записи slug в nginxproxy/docker-compose.yml
#   4. Перезагружает контейнеры php (если есть) и nginx проекта
#   5. Применяет docker-compose.yml nginxproxy и перезагружает его
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

# ==================== Запуск контейнеров проекта =
start_project_containers() {
    info "Запускаю контейнеры проекта ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в ${PROJECT_DIR}"
    
    if docker compose up -d --build; then
        info "Контейнеры проекта ${SLUG} запущены"
    else
        warn "Возникли проблемы при запуске контейнеров"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Включение конфига сайта в nginxproxy ====
# deactivate.sh переименовывает конфиг в <slug>.conf.disabled
enable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "${SITE_CONF}.disabled" ]]; then
        mv "${SITE_CONF}.disabled" "$SITE_CONF"
        info "Конфиг ${SLUG}.conf включён"
    elif [[ ! -f "$SITE_CONF" ]]; then
        warn "Конфиг ${SITE_CONF} не найден — сайт не будет доступен через nginxproxy"
    fi
}

# ==================== Раскомментирование в docker-compose.yml ====
uncomment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "Файл docker-compose.yml не найден: ${COMPOSE_FILE}"
    fi
    
    info "Раскомментирую записи ${SLUG} в docker-compose.yml..."
    
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
    
    # Раскомментируем сеть из x-common-networks
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        result.append(line)
        i += 1
        # Обрабатываем список сетей
        while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
            if is_slug_item(lines[i]) and lines[i].strip().startswith("# "):
                # Раскомментируем строку с нужным slug
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Раскомментируем volume из сервиса nginxproxy
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and (lines[i].strip().startswith("-") or lines[i].strip().startswith("# -")):
            if is_slug_item(lines[i]) and lines[i].strip().startswith("# "):
                # Раскомментируем строку с нужным slug
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
            else:
                result.append(lines[i])
            i += 1
        continue
    
    # Раскомментируем network на верхнем уровне
    if re.match(r'^networks:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это закомментированный блок с нужным slug
            if lines[i].strip().startswith(f"# {slug}:"):
                # Раскомментируем заголовок блока
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
                i += 1
                # Раскомментируем все дочерние элементы
                while i < len(lines) and lines[i].strip().startswith("#") and lines[i].startswith('  '):
                    uncommented = lines[i].replace("# ", "", 1)
                    result.append(uncommented)
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    # Раскомментируем volume на верхнем уровне
    if re.match(r'^volumes:\s*$', line):
        result.append(line)
        i += 1
        while i < len(lines):
            # Проверяем, не началась ли новая секция верхнего уровня
            if lines[i] and not lines[i].startswith(' '):
                break
            # Если это закомментированный блок с нужным slug
            if lines[i].strip().startswith(f"# {slug}_ssl_certificates:"):
                # Раскомментируем заголовок блока
                uncommented = lines[i].replace("# ", "", 1)
                result.append(uncommented)
                i += 1
                # Раскомментируем все дочерние элементы
                while i < len(lines) and lines[i].strip().startswith("#") and lines[i].startswith('  '):
                    uncommented = lines[i].replace("# ", "", 1)
                    result.append(uncommented)
                    i += 1
            else:
                result.append(lines[i])
                i += 1
        continue
    
    result.append(line)
    i += 1

with open(compose_file, 'w') as f:
    f.write("\n".join(result) + "\n")

print(f"Записи {slug} раскомментированы в docker-compose.yml")
PYEOF

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml успешно обновлён"
    else
        error "Не удалось обновить docker-compose.yml"
    fi
}

# ==================== Перезагрузка контейнеров проекта =
restart_project_services() {
    cd "${PROJECT_DIR}" || error "Не удалось перейти в ${PROJECT_DIR}"

    # У HTML-проектов сервиса php нет — перезапускаем только существующие
    local SERVICES
    SERVICES=$(docker compose config --services 2>/dev/null | grep -xE 'php|nginx' | tr '\n' ' ' || true)
    info "Перезагружаю ${SERVICES:-nginx }проекта ${SLUG}..."

    # shellcheck disable=SC2086
    if docker compose restart ${SERVICES:-nginx}; then
        info "Контейнеры ${SERVICES:-nginx }проекта ${SLUG} перезагружены"
    else
        warn "Возникли проблемы при перезагрузке контейнеров"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Перезагрузка nginxproxy ========
restart_nginxproxy() {
    info "Применяю docker-compose.yml nginxproxy и перезагружаю его..."

    # up -d нужен, чтобы прокси снова подключился к раскомментированной сети проекта;
    # restart — чтобы перечитать конфиги сайтов
    if (cd "${PROXY_DIR}" && docker compose up -d) && docker restart nginxproxy; then
        info "nginxproxy успешно перезагружен"
    else
        warn "Возникли проблемы при перезагрузке nginxproxy"
    fi
}

# ==================== Вывод итоговой информации =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Активация проекта завершена!"
    echo "============================================================"
    echo ""
    echo "ПРОЕКТ: ${SLUG}"
    echo "  Статус:         АКТИВИРОВАН"
    echo ""
    echo "Что было сделано:"
    echo "  ✓ Контейнеры проекта запущены (docker compose up -d --build)"
    echo "  ✓ Конфиг nginxproxy/sites/${SLUG}.conf включён"
    echo "  ✓ Записи раскомментированы в nginxproxy/docker-compose.yml"
    echo "  ✓ Контейнеры php (если есть) и nginx проекта перезагружены"
    echo "  ✓ nginxproxy перезагружен"
    echo ""
    echo "Проект доступен по адресу, указанному в конфигурации"
    echo ""
    echo "Для деактивации проекта используйте:"
    echo "  sudo bash deactivate.sh --slug ${SLUG}"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    
    info "Начинаю активацию проекта ${SLUG}..."
    echo ""
    
    start_project_containers
    enable_site_conf
    uncomment_in_docker_compose
    restart_project_services
    restart_nginxproxy
    
    print_summary
}

main "$@"
