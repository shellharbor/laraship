#!/bin/bash
set -euo pipefail

# ============================================================
# deploy-laravel.sh — развёртывание Laravel (+ Filament) в Docker
# ============================================================
# Использование:
#   sudo bash deploy-laravel.sh \
#     --slug m311 \
#     --domain m311.example.com \
#     --db-type postgres \
#     --install-filament --filament-email admin@example.com \
#     --ssl-email admin@example.com
#
# Все пароли и имена БД генерируются автоматически, если не указаны явно.
#
# Обязательные аргументы:
#   --domain DOMAIN              Домен сайта (без --slug к нему добавится случайный slug)
#   --db-type postgres|mysql     Тип БД
#   --ssl-email EMAIL            Email для Let's Encrypt (не нужен при --no-ssl)
#
# Проект:
#   --slug SLUG                  Идентификатор проекта (по умолчанию — случайный)
#   --laravel-version X.Y        Версия Laravel (минимум 10.0, по умолчанию 13.0)
#   --create-backup              Создать zip-архив проекта в /tmp после развёртывания
#   --endpoint URL               Отправить данные проекта (JSON, PUT) на URL
#
# Filament:
#   --install-filament           Установить filament/filament и панель /admin
#   --filament-email EMAIL       Email администратора (обязателен с --install-filament)
#   --filament-name NAME         Имя администратора (генерируется, если не указано)
#   --filament-password PASS     Пароль администратора (генерируется, если не указан)
#
# База данных:
#   --db-native                  Использовать БД на хосте, а не в контейнере
#   --db-root-password PASS      Root-пароль нативной MySQL (обязателен с --db-native + mysql)
#   --db-mysql-name, --db-mysql-user, --db-mysql-password, --db-mysql-root-password
#   --db-postgres-name, --db-postgres-user, --db-postgres-password
#
# Порты (по умолчанию — случайный свободный порт из диапазона):
#   --port-http      8100–8400      --port-php       9100–9600
#   --port-https     4100–4300      --port-redis     6500–6800
#   --port-mysql     3400–3600      --port-postgres  5500–5800
#   Для нативной БД порт по умолчанию 3306 / 5432.
#
# Прочее:
#   --redis-password PASS        Пароль Redis
#   --create-dhparam             Создать dhparam.pem для SSL (занимает несколько минут)
#   --enable-basic-auth          Включить HTTP Basic Authentication
#   --auth-user USER             Пользователь Basic Auth (генерируется, если не указан)
#   --auth-password PASS         Пароль Basic Auth (генерируется, если не указан)
#   --no-ssl                     Не получать SSL-сертификат
#   -h, --help                   Показать эту справку
#
# Скрипт должен лежать рядом с папками-шаблонами laravel/ и nginxproxy/.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
APP_TYPE="laravel"
TEMPLATE_DIR="${SCRIPT_DIR}/${APP_TYPE}"

# ======================== Цвета =============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Печатает шапку этого файла как справку
usage() {
    awk 'NR < 5 { next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ==================== Генерация случайных учетных данных ====================
# random_string <набор символов для tr> <длина>
random_string() {
    local CHARSET=$1
    local LENGTH=$2
    local RESULT=""
    # head закрывает пайп раньше tr (SIGPIPE) — с pipefail это ненулевой код, поэтому || true
    RESULT=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$CHARSET" | head -c "$LENGTH") || true
    echo "$RESULT"
}

# generate_random_name - генерирует имя (15 символов)
# Всегда начинается с буквы для совместимости с SQL
generate_random_name() {
    echo "$(random_string 'a-z' 1)$(random_string 'a-z0-9' 14)"
}

# generate_random_password - генерирует сложный пароль (15 символов)
# Без символов, ломающих sed (&, |, /, \), .env и docker compose ($, #, =, кавычки)
generate_random_password() {
    random_string 'A-Za-z0-9@%_+-' 15
}

# generate_random_slug - генерирует случайный slug (8 символов)
generate_random_slug() {
    random_string 'a-z0-9' 8
}

# Экранирует строку для правой части sed-замены (s|...|ЗДЕСЬ|)
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# ==================== Поиск свободного порта ====================
# find_free_port <min> <max> <описание>
# Выбирает случайный свободный порт из диапазона [min, max]
find_free_port() {
    local MIN=$1
    local MAX=$2
    local DESC=$3
    local RANGE=$((MAX - MIN + 1))
    local ATTEMPTS=0
    local MAX_ATTEMPTS=100

    while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
        local PORT=$(( RANDOM % RANGE + MIN ))
        # Проверяем через ss что порт не занят
        if ! ss -tlnp 2>/dev/null | grep -q ":${PORT} " && \
           ! ss -ulnp 2>/dev/null | grep -q ":${PORT} "; then
            echo "$PORT"
            return 0
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
    done

    error "Не удалось найти свободный порт для ${DESC} в диапазоне ${MIN}-${MAX}"
}

# ==================== Установка недостающих пакетов ====================
ensure_packages() {
    local MISSING=()
    local PKG
    for PKG in "$@"; do
        command -v "$PKG" &>/dev/null || MISSING+=("$PKG")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Не установлены: ${MISSING[*]}. Устанавливаю..."
        apt-get update -qq && apt-get install -y -qq "${MISSING[@]}"
    fi
}

# ==================== Проверка root =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт нужно запускать от root (sudo)."
    fi
}

# ==================== Проверка/создание /var/www ====
ensure_www_dir() {
    if [[ ! -d "$WWW_DIR" ]]; then
        info "Папка ${WWW_DIR} не существует, создаю..."
        mkdir -p "$WWW_DIR" || error "Не удалось создать папку ${WWW_DIR}"
        info "Папка ${WWW_DIR} успешно создана"
    else
        info "Папка ${WWW_DIR} уже существует"
    fi
}

# ==================== Установка Docker ======================
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker уже установлен: $(docker --version)"
        return
    fi

    info "Устанавливаю Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    info "Docker установлен: $(docker --version)"
}

# ==================== Инициализация nginxproxy ===============
init_nginxproxy() {
    if [[ -d "${PROXY_DIR}" ]]; then
        info "Папка ${PROXY_DIR} уже существует, пропускаю инициализацию."
        return
    fi

    info "Создаю ${PROXY_DIR} из шаблона..."
    mkdir -p "${PROXY_DIR}/sites"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.Dockerfile"   "${PROXY_DIR}/nginx.Dockerfile"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.conf"         "${PROXY_DIR}/nginx.conf"
    cp "${SCRIPT_DIR}/nginxproxy/site-template.conf" "${PROXY_DIR}/site-template.conf"

    # Базовый docker-compose.yml прокси — без сетей/томов, они добавляются для каждого сайта
    cat > "${PROXY_DIR}/docker-compose.yml" <<'DCEOF'
# cd /var/www/nginxproxy && docker compose up -d && docker restart nginxproxy
x-common-networks: &common-networks
  networks: []
services:
  nginxproxy:
    container_name: nginxproxy
    restart: always
    build:
      context: .
      dockerfile: nginx.Dockerfile
    # Раз в 6 часов перечитываем конфиг, чтобы подхватить продлённые сертификаты сайтов
    command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./sites:/etc/nginx/sites:ro
    <<: *common-networks
networks:
volumes:
DCEOF

    info "nginxproxy инициализирован в ${PROXY_DIR}"
}

# ==================== Создание dhparam.pem ===================
create_dhparam() {
    local DHPARAM_FILE="${PROXY_DIR}/dhparam.pem"

    if [[ "$CREATE_DHPARAM" != true ]]; then
        return
    fi

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "Файл dhparam.pem уже существует: ${DHPARAM_FILE}"
        return
    fi

    info "Создаю dhparam.pem (это займёт несколько минут)..."
    docker run --rm -v "${PROXY_DIR}:/output" alpine/openssl dhparam -out /output/dhparam.pem 2048

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "dhparam.pem успешно создан: ${DHPARAM_FILE}"
    else
        error "Не удалось создать dhparam.pem"
    fi
}

# ==================== Парсинг аргументов ====================
SLUG=""
DOMAIN=""
LARAVEL_VERSION="13.0"
PORT_HTTP=""
PORT_HTTPS=""
PORT_PHP=""
PORT_REDIS=""
REDIS_PASSWORD=""
DB_TYPE=""
PORT_MYSQL=""
PORT_POSTGRES=""
DB_MYSQL_NAME=""
DB_MYSQL_USER=""
DB_MYSQL_PASSWORD=""
DB_MYSQL_ROOT_PASSWORD=""
DB_POSTGRES_NAME=""
DB_POSTGRES_USER=""
DB_POSTGRES_PASSWORD=""
DB_NATIVE=false
DB_ROOT_PASSWORD=""
CREATE_DHPARAM=false
ENABLE_BASIC_AUTH=false
AUTH_USER=""
AUTH_PASSWORD=""
OBTAIN_SSL=true
SSL_EMAIL=""
ENDPOINT=""
INSTALL_FILAMENT=false
FILAMENT_EMAIL=""
FILAMENT_NAME=""
FILAMENT_PASSWORD=""
CREATE_BACKUP=false
BACKUP_FILE_PATH=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)                   SLUG="$2";                   shift 2 ;;
            --domain)                 DOMAIN="$2";                 shift 2 ;;
            --type)
                # Совместимость с вызовами старого deploy.sh
                [[ "$2" == "$APP_TYPE" ]] || error "Этот скрипт разворачивает только Laravel. Для '$2' используйте deploy-$2.sh"
                shift 2 ;;
            --laravel-version)        LARAVEL_VERSION="$2";        shift 2 ;;
            --install-filament)       INSTALL_FILAMENT=true;       shift 1 ;;
            --filament-email)         FILAMENT_EMAIL="$2";         shift 2 ;;
            --filament-name)          FILAMENT_NAME="$2";          shift 2 ;;
            --filament-password)      FILAMENT_PASSWORD="$2";      shift 2 ;;
            --create-backup)          CREATE_BACKUP=true;          shift 1 ;;
            --port-http)              PORT_HTTP="$2";              shift 2 ;;
            --port-https)             PORT_HTTPS="$2";             shift 2 ;;
            --port-php)               PORT_PHP="$2";               shift 2 ;;
            --port-redis)             PORT_REDIS="$2";             shift 2 ;;
            --port-postgres)          PORT_POSTGRES="$2";          shift 2 ;;
            --port-mysql)             PORT_MYSQL="$2";             shift 2 ;;
            --redis-password)         REDIS_PASSWORD="$2";         shift 2 ;;
            --db-type)                DB_TYPE="$2";                shift 2 ;;
            --db-mysql-name)          DB_MYSQL_NAME="$2";          shift 2 ;;
            --db-mysql-user)          DB_MYSQL_USER="$2";          shift 2 ;;
            --db-mysql-password)      DB_MYSQL_PASSWORD="$2";      shift 2 ;;
            --db-mysql-root-password) DB_MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
            --db-postgres-name)       DB_POSTGRES_NAME="$2";       shift 2 ;;
            --db-postgres-user)       DB_POSTGRES_USER="$2";       shift 2 ;;
            --db-postgres-password)   DB_POSTGRES_PASSWORD="$2";   shift 2 ;;
            --db-native)              DB_NATIVE=true;              shift 1 ;;
            --db-root-password)       DB_ROOT_PASSWORD="$2";       shift 2 ;;
            --create-dhparam)         CREATE_DHPARAM=true;         shift 1 ;;
            --enable-basic-auth)      ENABLE_BASIC_AUTH=true;      shift 1 ;;
            --auth-user)              AUTH_USER="$2";              shift 2 ;;
            --auth-password)          AUTH_PASSWORD="$2";          shift 2 ;;
            --obtain-ssl)             OBTAIN_SSL=true;             shift 1 ;;
            --no-ssl)                 OBTAIN_SSL=false;            shift 1 ;;
            --ssl-email)              SSL_EMAIL="$2";              shift 2 ;;
            --endpoint)               ENDPOINT="$2";               shift 2 ;;
            *) error "Неизвестный аргумент: $1 (см. --help)" ;;
        esac
    done

    [[ -z "$DOMAIN" ]]  && error "Не указан --domain"
    [[ -z "$DB_TYPE" ]] && error "Не указан --db-type"

    if [[ "$DB_TYPE" != "postgres" && "$DB_TYPE" != "mysql" ]]; then
        error "Тип БД должен быть 'postgres' или 'mysql', получено: ${DB_TYPE}"
    fi

    # --- Проверка root-пароля для нативного MySQL ---
    if [[ "$DB_NATIVE" == true && "$DB_TYPE" == "mysql" && -z "$DB_ROOT_PASSWORD" ]]; then
        error "Для нативной MySQL БД необходимо указать --db-root-password"
    fi

    if [[ "$OBTAIN_SSL" == true && -z "$SSL_EMAIL" ]]; then
        error "Для получения SSL-сертификата необходимо указать --ssl-email"
    fi

    # --- Filament: проверяем до начала установки, а не после ---
    if [[ "$INSTALL_FILAMENT" == true && -z "$FILAMENT_EMAIL" ]]; then
        error "Для установки Filament необходимо указать --filament-email"
    fi

    # --- Генерация slug, если не указан ---
    if [[ -z "$SLUG" ]]; then
        SLUG=$(generate_random_slug)
        DOMAIN="${SLUG}.${DOMAIN}"
        info "Сгенерирован slug: ${SLUG}"
        info "Обновлён домен: ${DOMAIN}"
    fi

    if ! [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        error "Недопустимый slug: ${SLUG} (разрешены буквы, цифры, '-' и '_')"
    fi
    if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Недопустимый домен: ${DOMAIN}"
    fi

    # --- Валидация версии Laravel ---
    if ! [[ "$LARAVEL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        error "Неверный формат версии Laravel: ${LARAVEL_VERSION}. Ожидается формат X.Y (например: 12.0)"
    fi
    local MAJOR_VERSION="${LARAVEL_VERSION%%.*}"
    if [[ $MAJOR_VERSION -lt 10 ]]; then
        error "Минимальная поддерживаемая версия Laravel: 10.0, указана: ${LARAVEL_VERSION}"
    fi
    info "Будет установлен Laravel версии ^${LARAVEL_VERSION}"

    # --- Генерация Redis пароля, если не указан ---
    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD=$(generate_random_password)
        info "Сгенерирован пароль Redis: ${REDIS_PASSWORD}"
    fi

    # --- Генерация учетных данных MySQL, если не указаны ---
    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ -z "$DB_MYSQL_NAME" ]]; then
            DB_MYSQL_NAME=$(generate_random_name)
            info "Сгенерировано имя БД MySQL: ${DB_MYSQL_NAME}"
        fi
        if [[ -z "$DB_MYSQL_USER" ]]; then
            DB_MYSQL_USER=$(generate_random_name)
            info "Сгенерирован пользователь MySQL: ${DB_MYSQL_USER}"
        fi
        if [[ -z "$DB_MYSQL_PASSWORD" ]]; then
            DB_MYSQL_PASSWORD=$(generate_random_password)
            info "Сгенерирован пароль MySQL: ${DB_MYSQL_PASSWORD}"
        fi
        if [[ -z "$DB_MYSQL_ROOT_PASSWORD" ]]; then
            DB_MYSQL_ROOT_PASSWORD=$(generate_random_password)
            info "Сгенерирован root пароль MySQL: ${DB_MYSQL_ROOT_PASSWORD}"
        fi
    fi

    # --- Генерация учетных данных PostgreSQL, если не указаны ---
    if [[ "$DB_TYPE" == "postgres" ]]; then
        if [[ -z "$DB_POSTGRES_NAME" ]]; then
            DB_POSTGRES_NAME=$(generate_random_name)
            info "Сгенерировано имя БД PostgreSQL: ${DB_POSTGRES_NAME}"
        fi
        if [[ -z "$DB_POSTGRES_USER" ]]; then
            DB_POSTGRES_USER=$(generate_random_name)
            info "Сгенерирован пользователь PostgreSQL: ${DB_POSTGRES_USER}"
        fi
        if [[ -z "$DB_POSTGRES_PASSWORD" ]]; then
            DB_POSTGRES_PASSWORD=$(generate_random_password)
            info "Сгенерирован пароль PostgreSQL: ${DB_POSTGRES_PASSWORD}"
        fi
    fi

    # --- Генерация учетных данных Basic Auth, если не указаны ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        if [[ -z "$AUTH_USER" ]]; then
            AUTH_USER=$(generate_random_name)
            info "Сгенерирован пользователь Basic Auth: ${AUTH_USER}"
        fi
        if [[ -z "$AUTH_PASSWORD" ]]; then
            AUTH_PASSWORD=$(generate_random_password)
            info "Сгенерирован пароль Basic Auth: ${AUTH_PASSWORD}"
        fi
    fi

    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        error "Папка шаблона не найдена: ${TEMPLATE_DIR}"
    fi
}

# ==================== Назначение портов ====================
# Порты, указанные вручную, не меняются; остальные подбираются из диапазонов
assign_ports() {
    info "Подбираю свободные порты..."

    if [[ -z "$PORT_HTTP" ]]; then
        PORT_HTTP=$(find_free_port 8100 8400 "HTTP")
    fi
    info "  HTTP:       ${PORT_HTTP}"

    if [[ -z "$PORT_HTTPS" ]]; then
        PORT_HTTPS=$(find_free_port 4100 4300 "HTTPS")
    fi
    info "  HTTPS:      ${PORT_HTTPS}"

    if [[ -z "$PORT_PHP" ]]; then
        PORT_PHP=$(find_free_port 9100 9600 "PHP-FPM")
    fi
    info "  PHP-FPM:    ${PORT_PHP}"

    if [[ -z "$PORT_REDIS" ]]; then
        PORT_REDIS=$(find_free_port 6500 6800 "Redis")
    fi
    info "  Redis:      ${PORT_REDIS}"

    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_MYSQL="${PORT_MYSQL:-3306}"
            info "  MySQL:      ${PORT_MYSQL} (нативная БД)"
        else
            if [[ -z "$PORT_MYSQL" ]]; then
                PORT_MYSQL=$(find_free_port 3400 3600 "MySQL")
            fi
            info "  MySQL:      ${PORT_MYSQL}"
        fi
    else
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_POSTGRES="${PORT_POSTGRES:-5432}"
            info "  PostgreSQL: ${PORT_POSTGRES} (нативная БД)"
        else
            if [[ -z "$PORT_POSTGRES" ]]; then
                PORT_POSTGRES=$(find_free_port 5500 5800 "PostgreSQL")
            fi
            info "  PostgreSQL: ${PORT_POSTGRES}"
        fi
    fi
}

# ==================== Настройка БД в docker-compose.yml ======
# Удаляет неиспользуемый контейнер БД (и выбранный — при нативной БД),
# их volumes и зависимости, а выбранную БД переименовывает в db / <slug>_db
configure_compose_db() {
    local COMPOSE_FILE="$1"

    if [[ "$DB_NATIVE" == true ]]; then
        info "Удаляю контейнеры БД из docker-compose.yml (используется нативная БД)..."
    else
        info "Настраиваю docker-compose.yml для БД типа ${DB_TYPE}..."
    fi

    python3 - "$COMPOSE_FILE" "$SLUG" "$DB_TYPE" "$DB_NATIVE" <<'PYEOF'
import re
import sys

path, slug, db_type, native = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'true'
other = 'mysql' if db_type == 'postgres' else 'postgres'

drop_services = {f'db_{other}'}
drop_volumes = {f'{slug}_db_{other}'}
if native:
    drop_services.add(f'db_{db_type}')
    drop_volumes.add(f'{slug}_db_{db_type}')

with open(path) as f:
    lines = f.read().splitlines()

# --- 1. Удаляем блоки сервисов и volumes ---
result = []
section = None
skipping = False
for line in lines:
    top = re.match(r'^([A-Za-z][\w-]*):', line)
    if top:
        section = top.group(1)
        skipping = False
        result.append(line)
        continue

    key = re.match(r'^  ([\w.-]+):\s*$', line)
    if key:
        name = key.group(1)
        skipping = (section == 'services' and name in drop_services) or \
                   (section == 'volumes' and name in drop_volumes)
        if not skipping:
            result.append(line)
        continue

    if skipping:
        # Внутри удаляемого блока: пустые строки и всё с отступом больше 2
        if line.strip() == '' or len(line) - len(line.lstrip()) > 2:
            continue
        skipping = False

    result.append(line)

# --- 2. Нативная БД: убираем зависимости от контейнера БД ---
if native:
    db_names = {'db', 'db_postgres', 'db_mysql'}
    cleaned = []
    i = 0
    while i < len(result):
        line = result[i]
        if line.strip() == 'depends_on:':
            indent = len(line) - len(line.lstrip())
            items = []
            i += 1
            while i < len(result) and re.match(r'^\s+-\s+', result[i]) \
                    and len(result[i]) - len(result[i].lstrip()) > indent:
                if result[i].strip()[1:].strip() not in db_names:
                    items.append(result[i])
                i += 1
            if items:
                cleaned.append(line)
                cleaned.extend(items)
            continue
        cleaned.append(line)
        i += 1
    result = cleaned

# --- 3. Переименовываем выбранную БД: db_postgres → db, <slug>_db_postgres → <slug>_db ---
result = [re.sub(rf'\bdb_{db_type}\b', 'db', l.replace(f'{slug}_db_{db_type}', f'{slug}_db'))
          for l in result]

with open(path, 'w') as f:
    f.write('\n'.join(result) + '\n')
PYEOF
}

# ==================== Генерация .env проекта ======================
write_project_env() {
    local ENV_FILE="${PROJECT_DIR}/.env"

    info "Генерирую .env для ${SLUG}..."
    {
        echo "SITE_HOST=${DOMAIN}"
        echo "SITE_PORT_HTTP=${PORT_HTTP}"
        echo "SITE_PORT_HTTPS=${PORT_HTTPS}"
        echo ""
        echo "PHP_PORT=${PORT_PHP}"
        echo ""
        echo "REDIS_PORT=${PORT_REDIS}"
        echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
        echo ""
        if [[ "$DB_TYPE" == "postgres" ]]; then
            echo "DB_PORT=${PORT_POSTGRES}"
            echo "DB_POSTGRES_NAME=${DB_POSTGRES_NAME}"
            echo "DB_POSTGRES_USER=${DB_POSTGRES_USER}"
            echo "DB_POSTGRES_PASSWORD=${DB_POSTGRES_PASSWORD}"
        else
            echo "DB_PORT=${PORT_MYSQL}"
            echo "DB_MYSQL_NAME=${DB_MYSQL_NAME}"
            echo "DB_MYSQL_USER=${DB_MYSQL_USER}"
            echo "DB_MYSQL_PASSWORD=${DB_MYSQL_PASSWORD}"
            echo "DB_MYSQL_PASSWORD_ROOT=${DB_MYSQL_ROOT_PASSWORD}"
        fi
        echo ""
        echo "DB_NATIVE=${DB_NATIVE}"
        if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
            echo ""
            echo "AUTH_USER=${AUTH_USER}"
            echo "AUTH_PASSWORD=${AUTH_PASSWORD}"
        fi
    } > "$ENV_FILE"
}

# ==================== Создание проекта ======================
create_project() {
    PROJECT_DIR="${WWW_DIR}/${SLUG}"

    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Папка проекта уже существует: ${PROJECT_DIR}"

        # Проверяем, запущены ли контейнеры проекта
        info "Проверяю наличие контейнеров проекта..."

        local RUNNING_CONTAINERS
        local ALL_CONTAINERS
        RUNNING_CONTAINERS=$(docker ps -q --filter "name=${SLUG}_" 2>/dev/null | wc -l)
        ALL_CONTAINERS=$(docker ps -aq --filter "name=${SLUG}_" 2>/dev/null | wc -l)

        if [[ $ALL_CONTAINERS -eq 0 ]]; then
            warn "Контейнеры проекта не найдены. Удаляю папку проекта..."
        else
            if [[ $RUNNING_CONTAINERS -gt 0 ]]; then
                warn "Контейнеры проекта запущены ($RUNNING_CONTAINERS из $ALL_CONTAINERS). Останавливаю..."
                cd "$PROJECT_DIR" || error "Не удалось перейти в ${PROJECT_DIR}"
                docker compose down
                cd "${SCRIPT_DIR}" || true
                info "Контейнеры остановлены"
            fi
            warn "Удаляю папку проекта..."
        fi
        rm -rf "$PROJECT_DIR"
        info "Папка проекта удалена. Продолжаю создание..."
    fi

    info "Создаю проект ${SLUG} (${APP_TYPE}) в ${PROJECT_DIR}..."
    mkdir -p "${PROJECT_DIR}"

    # Копируем всё содержимое шаблона
    cp -a "${TEMPLATE_DIR}/." "${PROJECT_DIR}/"

    # --- Организация Dockerfile'ов в подпапки ---
    if [[ -d "${PROJECT_DIR}/.docker" ]]; then
        mkdir -p "${PROJECT_DIR}/.docker/php"
        mkdir -p "${PROJECT_DIR}/.docker/nginx"
        mkdir -p "${PROJECT_DIR}/.docker/init/postgres"

        if ls "${PROJECT_DIR}/.docker"/php*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/php*.Dockerfile "${PROJECT_DIR}/.docker/php/" 2>/dev/null || true
        fi
        if ls "${PROJECT_DIR}/.docker"/nginx*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/nginx*.Dockerfile "${PROJECT_DIR}/.docker/nginx/" 2>/dev/null || true
        fi
    fi

    # --- public_html: composer работает в PHP-образе от пользователя www (uid 1000) ---
    mkdir -p "${PROJECT_DIR}/public_html"
    chown 1000:1000 "${PROJECT_DIR}/public_html"

    # --- Замена {SLUG} → slug в docker-compose.yml ---
    sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/docker-compose.yml"

    # --- Контейнер БД: выбранный тип или нативная БД ---
    configure_compose_db "${PROJECT_DIR}/docker-compose.yml"

    # --- .env проекта ---
    write_project_env

    # --- Замена MYSITE.COM → domain в _site.conf ---
    if [[ -f "${PROJECT_DIR}/.config/nginx/_site.conf" ]]; then
        sed -i "s/MYSITE\.COM/${DOMAIN}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
        sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Раскомментирование dhparam.pem в docker-compose.yml и _site.conf ---
    if [[ "$CREATE_DHPARAM" == true ]]; then
        info "Раскомментирую строку dhparam.pem в docker-compose.yml..."
        # Проект лежит в /var/www/<slug>, прокси — в /var/www/nginxproxy, т.е. путь ../nginxproxy
        sed -i 's|^\s*#\s*-\s*\(\.\./\)\{1,2\}nginxproxy/dhparam\.pem:/etc/ssl/certs/dhparam\.pem.*|      - ../nginxproxy/dhparam.pem:/etc/ssl/certs/dhparam.pem:ro|' "${PROJECT_DIR}/docker-compose.yml"

        info "Раскомментирую строку ssl_dhparam в _site.conf..."
        sed -i 's|^\s*#ssl_dhparam /etc/ssl/certs/dhparam\.pem;|        ssl_dhparam /etc/ssl/certs/dhparam.pem;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Создание .htpasswd для Basic Auth ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        info "Создаю .htpasswd файл для Basic Authentication..."
        mkdir -p "${PROJECT_DIR}/.config/nginx"
        docker run --rm httpd:alpine htpasswd -nb "${AUTH_USER}" "${AUTH_PASSWORD}" > "${PROJECT_DIR}/.config/nginx/.htpasswd"

        if [[ -s "${PROJECT_DIR}/.config/nginx/.htpasswd" ]]; then
            info ".htpasswd файл создан: ${PROJECT_DIR}/.config/nginx/.htpasswd"

            info "Раскомментирую строку .htpasswd в docker-compose.yml..."
            sed -i 's|^\s*#\s*-\s*\./.config/nginx/\.htpasswd:/etc/nginx/\.htpasswd:ro|      - ./.config/nginx/.htpasswd:/etc/nginx/.htpasswd:ro|' "${PROJECT_DIR}/docker-compose.yml"

            info "Раскомментирую строки Basic Auth в _site.conf..."
            sed -i 's|^#\s*auth_basic "Restricted Access";|            auth_basic "Restricted Access";|' "${PROJECT_DIR}/.config/nginx/_site.conf"
            sed -i 's|^#\s*auth_basic_user_file /etc/nginx/\.htpasswd;|            auth_basic_user_file /etc/nginx/.htpasswd;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
        else
            error "Не удалось создать .htpasswd файл"
        fi
    fi

    info "Проект ${SLUG} создан в ${PROJECT_DIR}"
}

# ==================== Создание конфига сайта для nginxproxy ======
update_proxy_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"
    local TEMPLATE="${PROXY_DIR}/site-template.conf"

    mkdir -p "${PROXY_DIR}/sites"

    # Копируем шаблон, если его нет
    if [[ ! -f "$TEMPLATE" ]]; then
        info "Копирую site-template.conf в nginxproxy..."
        local SOURCE_TEMPLATE="${SCRIPT_DIR}/nginxproxy/site-template.conf"

        if [[ ! -f "$SOURCE_TEMPLATE" ]]; then
            error "Шаблон не найден: ${SOURCE_TEMPLATE}. SCRIPT_DIR=${SCRIPT_DIR}"
        fi

        cp "$SOURCE_TEMPLATE" "$TEMPLATE"
    fi

    # Проверяем, смонтирована ли папка sites в docker-compose.yml
    if ! grep -q "./sites:/etc/nginx/sites:ro" "${PROXY_DIR}/docker-compose.yml"; then
        info "Добавляю монтирование папки sites в docker-compose.yml nginxproxy..."
        sed -i '/- \.\/nginx\.conf:\/etc\/nginx\/nginx\.conf:ro/a\      - ./sites:/etc/nginx/sites:ro' "${PROXY_DIR}/docker-compose.yml"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        warn "Конфиг ${SITE_CONF} уже существует, пропускаю."
        return
    fi

    info "Создаю конфиг ${SLUG}.conf из шаблона..."
    sed -e "s/SLUG/${SLUG}/g" \
        -e "s/DOMAIN/${DOMAIN}/g" \
        "$TEMPLATE" > "$SITE_CONF"

    info "Конфиг ${SLUG}.conf создан в ${PROXY_DIR}/sites/"
}

# ==================== Обновление nginxproxy/docker-compose.yml
update_proxy_docker_compose() {
    local DC="${PROXY_DIR}/docker-compose.yml"

    # Проверяем, не добавлен ли уже этот slug в секции networks
    if grep -q "^  ${SLUG}:$" "$DC"; then
        info "Сеть ${SLUG} уже добавлена в ${DC}"
        return
    fi

    info "Добавляю ${SLUG} в ${DC}..."

    python3 - "$DC" "$SLUG" <<'PYEOF'
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

dc_path = sys.argv[1]
slug = sys.argv[2]

with open(dc_path) as f:
    content = f.read()

lines = content.splitlines()
result = []
i = 0

# Собираем существующие ключи для проверки дубликатов
existing_networks = set()
existing_volumes = set()
existing_network_refs = set()
existing_volume_mounts = set()

for line in lines:
    # Сети в x-common-networks
    match = re.match(r'^\s+-\s+([\w-]+)$', line)
    if match:
        existing_network_refs.add(match.group(1))
    # Сети на верхнем уровне
    match = re.match(r'^\s{2}([\w-]+):\s*$', line)
    if match:
        existing_networks.add(match.group(1))
    # Volumes на верхнем уровне
    match = re.match(r'^\s{2}([\w-]+_ssl_certificates):\s*$', line)
    if match:
        existing_volumes.add(match.group(1))
    # Volume mounts в сервисе
    match = re.match(r'^\s+-\s+([\w-]+_ssl_certificates):/etc/letsencrypt/', line)
    if match:
        existing_volume_mounts.add(match.group(1))

while i < len(lines):
    line = lines[i]

    # --- x-common-networks: добавляем сеть в список ---
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        if line.strip() == "networks: []":
            # Заменяем inline-синтаксис на многострочный с новой сетью
            result.append("  networks:")
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
            i += 1
        else:
            result.append(line)
            i += 1
            while i < len(lines) and lines[i].strip().startswith("-"):
                result.append(lines[i])
                i += 1
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
        continue

    # --- volumes: в сервисе nginxproxy — добавляем ssl volume ---
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volume_mounts:
            result.append(f"      - {volume_key}:/etc/letsencrypt/{slug}")
        continue

    # --- networks: на верхнем уровне ---
    if re.match(r'^networks:\s*(\{\})?$', line):
        result.append("networks:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        if slug not in existing_networks:
            result.append(f"  {slug}:")
            result.append(f"    name: {slug}")
            result.append(f"    external: true")
        continue

    # --- volumes: на верхнем уровне ---
    if re.match(r'^volumes:\s*(\{\})?$', line):
        result.append("volumes:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volumes:
            result.append(f"  {volume_key}:")
            result.append(f"    name: {volume_key}")
            result.append(f"    external: true")
        continue

    result.append(line)
    i += 1

with open(dc_path, 'w') as f:
    f.write("\n".join(result) + "\n")
PYEOF

    info "${SLUG} добавлен в docker-compose.yml прокси"
}

# ==================== Комментирование / раскомментирование SSL-блоков ==============
# toggle_ssl_blocks comment|uncomment
# Работает с server-блоком "listen 443" в _site.conf проекта и в nginxproxy/sites/<slug>.conf
toggle_ssl_blocks() {
    local MODE="$1"
    local FILES=()
    local FILE

    for FILE in "${PROJECT_DIR}/.config/nginx/_site.conf" "${PROXY_DIR}/sites/${SLUG}.conf"; do
        [[ -f "$FILE" ]] && FILES+=("$FILE")
    done
    [[ ${#FILES[@]} -eq 0 ]] && return 0

    python3 - "$MODE" "${FILES[@]}" <<'PYEOF'
import sys
import re

mode, paths = sys.argv[1], sys.argv[2:]

for conf_path in paths:
    with open(conf_path) as f:
        lines = f.read().splitlines()

    result = []
    in_ssl_block = False
    brace_count = 0

    for idx, line in enumerate(lines):
        if not in_ssl_block:
            window = lines[idx:idx + 10]
            if mode == 'comment':
                starts = re.match(r'^\s*server\s*\{', line) and any('listen 443' in l for l in window)
            else:
                starts = re.match(r'^#\s*server\s*\{', line) and \
                    any(l.startswith('#') and 'listen 443' in l for l in window)
            if starts:
                in_ssl_block = True
                brace_count = 1
                result.append('#' + line if mode == 'comment' else line[1:])
            else:
                result.append(line)
            continue

        if mode == 'comment':
            body = line
            result.append('#' + line)
        else:
            body = line[1:] if line.startswith('#') else line
            result.append(body)

        brace_count += body.count('{') - body.count('}')
        if brace_count == 0:
            in_ssl_block = False

    with open(conf_path, 'w') as f:
        f.write('\n'.join(result) + '\n')
PYEOF

    for FILE in "${FILES[@]}"; do
        if [[ "$MODE" == "comment" ]]; then
            info "SSL-блок закомментирован в ${FILE}"
        else
            info "SSL-блок раскомментирован в ${FILE}"
        fi
    done
}

comment_ssl_blocks() {
    info "Комментирую SSL-блоки до получения сертификата..."
    toggle_ssl_blocks comment
}

uncomment_ssl_blocks() {
    info "Раскомментирую SSL-блоки после получения сертификата..."
    toggle_ssl_blocks uncomment
}

# ==================== Создание нативной базы данных ==============
create_native_database() {
    if [[ "$DB_NATIVE" != true ]]; then
        return
    fi

    info "Создаю нативную базу данных ${DB_TYPE}..."

    if [[ "$DB_TYPE" == "postgres" ]]; then
        if ! command -v psql &> /dev/null; then
            error "PostgreSQL не установлен на сервере. Установите PostgreSQL или используйте контейнерную БД (уберите флаг --db-native)"
        fi

        if ! sudo -u postgres psql -c "SELECT 1;" &> /dev/null; then
            error "PostgreSQL сервер не запущен или недоступен. Запустите PostgreSQL: sudo systemctl start postgresql"
        fi

        info "Создаю пользователя PostgreSQL: ${DB_POSTGRES_USER}"
        sudo -u postgres psql -c "CREATE USER \"${DB_POSTGRES_USER}\" WITH PASSWORD '${DB_POSTGRES_PASSWORD}';" 2>/dev/null || \
            warn "Пользователь ${DB_POSTGRES_USER} уже существует"

        info "Создаю базу данных PostgreSQL: ${DB_POSTGRES_NAME}"
        sudo -u postgres psql -c "CREATE DATABASE \"${DB_POSTGRES_NAME}\" OWNER \"${DB_POSTGRES_USER}\";" 2>/dev/null || \
            warn "База данных ${DB_POSTGRES_NAME} уже существует"

        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_POSTGRES_NAME}\" TO \"${DB_POSTGRES_USER}\";"

        success "PostgreSQL база данных ${DB_POSTGRES_NAME} создана"

    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if ! command -v mysql &> /dev/null; then
            error "MySQL не установлен на сервере. Установите MySQL или используйте контейнерную БД (уберите флаг --db-native)"
        fi

        if ! mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &> /dev/null; then
            error "MySQL сервер недоступен или неверный root-пароль. Проверьте: 1) MySQL запущен (sudo systemctl start mysql), 2) Правильность --db-root-password"
        fi

        info "Создаю базу данных MySQL: ${DB_MYSQL_NAME}"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_MYSQL_NAME}\`;" || \
            error "Не удалось создать базу данных MySQL. Проверьте root-пароль."

        # Приложение подключается из контейнера (через Docker bridge), а не с localhost
        info "Создаю пользователя MySQL: ${DB_MYSQL_USER}"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${DB_MYSQL_USER}'@'%' IDENTIFIED BY '${DB_MYSQL_PASSWORD}';"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${DB_MYSQL_NAME}\`.* TO '${DB_MYSQL_USER}'@'%';"
        mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

        success "MySQL база данных ${DB_MYSQL_NAME} создана"
    fi
}

# ==================== Сборка и запуск Docker ==============
build_and_start_project() {
    info "Запускаю сборку и запуск Docker-контейнеров проекта..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в директорию ${PROJECT_DIR}"

    # Создаём внешнюю сеть если её нет
    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        info "Создаю внешнюю сеть ${SLUG}..."
        if docker network create "${SLUG}" \
            --label "com.docker.compose.project=${SLUG}" \
            --label "com.docker.compose.network=${SLUG}"; then
            info "Сеть ${SLUG} успешно создана"
        else
            error "Не удалось создать сеть ${SLUG}"
        fi
    else
        info "Сеть ${SLUG} уже существует"
    fi

    info "Проверяю и создаю необходимые volumes..."
    local VOLUMES=("${SLUG}_ssl_certificates" "${SLUG}_certbot_www" "${SLUG}_redis_data")
    if [[ "$DB_NATIVE" != true ]]; then
        VOLUMES=("${SLUG}_db" "${VOLUMES[@]}")
    fi

    local VOLUME
    for VOLUME in "${VOLUMES[@]}"; do
        if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
            info "Создаю volume ${VOLUME}..."
            docker volume create "${VOLUME}"
        else
            info "Volume ${VOLUME} уже существует"
        fi
    done

    info "Выполняю: docker compose up -d --build"
    if ! docker compose up -d --build; then
        error "Не удалось собрать/запустить проект. Проверьте логи: cd ${PROJECT_DIR} && docker compose logs"
    fi

    info "Команда docker compose завершена успешно"

    # Даём контейнерам время на запуск
    info "Ожидаю запуска контейнеров..."
    sleep 10

    info "Проверяю статус контейнеров..."
    local RUNNING
    local ALL
    RUNNING=$(docker ps --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)
    ALL=$(docker ps -a --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)

    info "Запущено контейнеров: ${RUNNING} из ${ALL}"

    if [[ $RUNNING -eq 0 ]]; then
        warn "Контейнеры не запущены! Проверьте логи:"
        warn "  cd ${PROJECT_DIR} && docker compose logs"
    else
        info "Статус контейнеров:"
        docker ps -a --filter "name=${SLUG}_" --format "table {{.Names}}\t{{.Status}}"

        # Проверяем критичные контейнеры (php, nginx, db)
        local CRITICAL_RUNNING
        CRITICAL_RUNNING=$(docker ps --filter "name=${SLUG}_php" --filter "name=${SLUG}_nginx" --filter "name=${SLUG}_db" --format "{{.Names}}" | wc -l)
        if [[ $CRITICAL_RUNNING -ge 2 ]]; then
            info "Основные контейнеры (php, nginx, db) запущены"
        else
            warn "Некоторые критичные контейнеры не запустились. Проверьте логи."
        fi
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Установка Laravel через composer ==============
install_laravel() {
    info "Устанавливаю Laravel версии ^${LARAVEL_VERSION}..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в директорию ${PROJECT_DIR}"

    # Проверяем, не установлен ли уже Laravel (наличие artisan)
    if [[ -f "${PROJECT_DIR}/public_html/artisan" ]]; then
        warn "Laravel уже установлен в ${PROJECT_DIR}/public_html/"
        info "Пропускаю установку Laravel"
        cd "${SCRIPT_DIR}" || true
        return
    fi

    info "Запускаю: docker compose run --rm composer create-project laravel/laravel:^${LARAVEL_VERSION} ."

    if docker compose run --rm composer create-project "laravel/laravel:^${LARAVEL_VERSION}" .; then
        success "Laravel ^${LARAVEL_VERSION} успешно установлен!"

        info "Устанавливаю права доступа..."
        docker compose run --rm permissions

        info "Laravel готов к использованию в ${PROJECT_DIR}/public_html/"
    else
        error "Не удалось установить Laravel. Проверьте логи выше."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Настройка .env файла Laravel ==============
configure_laravel_env() {
    local LARAVEL_ENV="${PROJECT_DIR}/public_html/.env"

    if [[ ! -f "$LARAVEL_ENV" ]]; then
        warn ".env файл Laravel не найден: ${LARAVEL_ENV}"
        info "Пропускаю настройку Laravel .env"
        return
    fi

    info "Настраиваю .env файл Laravel..."

    local DB_CONNECTION=""
    local DB_HOST=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""
    local DB_PORT_VALUE=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_CONNECTION="pgsql"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_CONNECTION="mysql"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    # Нативная БД: IP Docker bridge и порт на хосте.
    # Контейнерная БД: имя контейнера и внутренний порт (внешний порт из .env внутри сети не слушается)
    if [[ "$DB_NATIVE" == true ]]; then
        DB_HOST="172.17.0.1"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="$PORT_POSTGRES"; else DB_PORT_VALUE="$PORT_MYSQL"; fi
    else
        DB_HOST="${SLUG}_db"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="5432"; else DB_PORT_VALUE="3306"; fi
    fi

    # Laravel 11+ держит DB_* закомментированными, Laravel 10 — нет; обрабатываем оба варианта
    sed -i "s|^#\? *DB_CONNECTION=.*|DB_CONNECTION=${DB_CONNECTION}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_HOST=.*|DB_HOST=${DB_HOST}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_PORT=.*|DB_PORT=${DB_PORT_VALUE}|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_DATABASE=.*|DB_DATABASE=$(sed_escape "$DB_NAME")|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_USERNAME=.*|DB_USERNAME=$(sed_escape "$DB_USER")|" "$LARAVEL_ENV"
    sed -i "s|^#\? *DB_PASSWORD=.*|DB_PASSWORD=$(sed_escape "$DB_PASS")|" "$LARAVEL_ENV"

    sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" "$LARAVEL_ENV"

    info "Параметры БД и APP_URL успешно записаны в ${LARAVEL_ENV}:"
    info "  APP_URL: https://${DOMAIN}"
    info "  DB_CONNECTION: ${DB_CONNECTION}"
    info "  DB_HOST: ${DB_HOST}"
    info "  DB_PORT: ${DB_PORT_VALUE}"
    info "  DB_DATABASE: ${DB_NAME}"
    info "  DB_USERNAME: ${DB_USER}"

    info "Выполняю миграции Laravel..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в директорию ${PROJECT_DIR}"

    if docker compose run --rm artisan migrate --force 2>&1; then
        success "Миграции Laravel успешно выполнены"
    else
        warn "Не удалось выполнить миграции Laravel. Проверьте подключение к БД и выполните миграции вручную:"
        warn "  cd ${PROJECT_DIR} && docker compose run --rm artisan migrate"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Установка Laravel Filament ==============
install_filament() {
    if [[ "$INSTALL_FILAMENT" != true ]]; then
        return
    fi

    info "Устанавливаю Laravel Filament..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в директорию ${PROJECT_DIR}"

    # Генерируем случайное имя если не указано (8 символов)
    if [[ -z "$FILAMENT_NAME" ]]; then
        FILAMENT_NAME=$(random_string 'a-f0-9' 8)
        info "Сгенерировано случайное имя пользователя: ${FILAMENT_NAME}"
    fi

    # Генерируем случайный пароль если не указан (10 символов)
    if [[ -z "$FILAMENT_PASSWORD" ]]; then
        FILAMENT_PASSWORD=$(random_string 'a-zA-Z0-9' 10)
        info "Сгенерирован случайный пароль: ${FILAMENT_PASSWORD}"
    fi

    info "Шаг 1/3: Установка пакета Filament..."
    if docker compose run --rm composer require filament/filament:"^5.0" 2>&1; then
        success "Пакет Filament успешно установлен"
    else
        error "Не удалось установить пакет Filament"
    fi

    info "Шаг 2/3: Установка панели Filament..."
    if docker compose run --rm artisan filament:install --panels 2>&1; then
        success "Панель Filament успешно установлена"
    else
        error "Не удалось установить панель Filament"
    fi

    info "Шаг 3/3: Создание пользователя Filament..."
    if docker compose run --rm artisan make:filament-user --name="${FILAMENT_NAME}" --email="${FILAMENT_EMAIL}" --password="${FILAMENT_PASSWORD}" 2>&1; then
        success "Пользователь Filament успешно создан"
        info "Данные для входа в Filament:"
        info "  Email: ${FILAMENT_EMAIL}"
        info "  Name: ${FILAMENT_NAME}"
        info "  Password: ${FILAMENT_PASSWORD}"
        info "  URL: https://${DOMAIN}/admin"

        local GLOBAL_ENV="${PROJECT_DIR}/.env"
        if [[ -f "$GLOBAL_ENV" ]]; then
            info "Сохраняю данные Filament в глобальный .env файл..."
            {
                echo ""
                echo "# Filament Admin Credentials"
                echo "FILAMENT_ADMIN_NAME=${FILAMENT_NAME}"
                echo "FILAMENT_ADMIN_EMAIL=${FILAMENT_EMAIL}"
                echo "FILAMENT_ADMIN_PASSWORD=${FILAMENT_PASSWORD}"
            } >> "$GLOBAL_ENV"
            success "Данные Filament сохранены в ${GLOBAL_ENV}"
        fi
    else
        error "Не удалось создать пользователя Filament"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Получение SSL-сертификата ===========
obtain_ssl_certificate() {
    if [[ "$OBTAIN_SSL" != true ]]; then
        info "Пропускаю получение SSL-сертификата (--no-ssl указан)"
        return
    fi

    info "Получаю SSL-сертификат для домена ${DOMAIN}..."
    cd "${PROJECT_DIR}" || error "Не удалось перейти в директорию ${PROJECT_DIR}"

    # Ошибка certbot не должна обрывать скрипт (set -e) — дальше ещё summary, endpoint, backup
    if docker compose run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        -d "${DOMAIN}" \
        --email "${SSL_EMAIL}" \
        --agree-tos \
        --non-interactive; then
        info "SSL-сертификат успешно получен для ${DOMAIN}!"

        uncomment_ssl_blocks

        info "Перезапускаю nginx проекта для применения SSL-конфигурации..."
        docker compose restart nginx

        info "Перезапускаю nginxproxy для применения SSL-конфигурации..."
        cd "${PROXY_DIR}" || error "Не удалось перейти в ${PROXY_DIR}"
        docker compose restart

        info "SSL-конфигурация успешно применена!"
    else
        warn "Не удалось получить SSL-сертификат. Проверьте:"
        warn "  - DNS-записи для ${DOMAIN} указывают на этот сервер"
        warn "  - Порты 80 и 443 открыты и доступны"
        warn "  - nginxproxy запущен и работает"
        warn "  - nginx проекта работает корректно"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Перезапуск nginxproxy ===================
restart_nginxproxy() {
    info "Перезапускаю nginxproxy для применения изменений..."
    cd "${PROXY_DIR}" || error "Не удалось перейти в ${PROXY_DIR}"

    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        warn "Сеть ${SLUG} не найдена. Пропускаю перезапуск nginxproxy."
        warn "Перезапустите nginxproxy вручную после запуска проекта:"
        warn "  cd ${PROXY_DIR} && docker compose up -d"
        cd "${SCRIPT_DIR}" || true
        return
    fi

    if docker compose up -d; then
        info "nginxproxy успешно перезапущен"

        sleep 3

        if docker ps --filter "name=nginxproxy" --format "{{.Names}}" | grep -q "nginxproxy"; then
            info "nginxproxy работает"
        else
            warn "nginxproxy не запущен. Проверьте логи:"
            warn "  cd ${PROXY_DIR} && docker compose logs"
        fi
    else
        warn "Возникли проблемы при перезапуске nginxproxy. Проверьте конфигурацию."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Отправка данных проекта на endpoint ====================
send_project_data() {
    if [[ -z "$ENDPOINT" ]]; then
        return
    fi

    info "Отправляю данные проекта на endpoint: ${ENDPOINT}..."

    local DB_PORT_VALUE=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_PORT_VALUE="$PORT_POSTGRES"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_PORT_VALUE="$PORT_MYSQL"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    local JSON_DATA
    JSON_DATA=$(cat <<JSONEOF
{
  "slug": "${SLUG}",
  "domain": "${DOMAIN}",
  "app_type": "${APP_TYPE}",
  "laravel_version": "${LARAVEL_VERSION}",
  "db_type": "${DB_TYPE}",
  "ports": {
    "http": ${PORT_HTTP},
    "https": ${PORT_HTTPS},
    "php": ${PORT_PHP},
    "redis": ${PORT_REDIS}
  },
  "redis": {
    "password": "${REDIS_PASSWORD}"
  },
  "database": {
    "type": "${DB_TYPE}",
    "port": ${DB_PORT_VALUE},
    "name": "${DB_NAME}",
    "user": "${DB_USER}",
    "password": "${DB_PASS}"
  },
  "basic_auth": {
    "enabled": ${ENABLE_BASIC_AUTH},
    "user": "${AUTH_USER}",
    "password": "${AUTH_PASSWORD}"
  },
  "ssl": {
    "enabled": ${OBTAIN_SSL},
    "email": "${SSL_EMAIL}"
  },
  "project_path": "${WWW_DIR}/${SLUG}"
}
JSONEOF
)

    local RESPONSE
    RESPONSE=$(curl -X PUT \
        -H "Content-Type: application/json" \
        -d "${JSON_DATA}" \
        -w "\n%{http_code}" \
        -s \
        "${ENDPOINT}" 2>&1) || true

    local HTTP_CODE
    local RESPONSE_BODY
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        success "Данные успешно отправлены на endpoint (HTTP ${HTTP_CODE})"
        if [[ -n "$RESPONSE_BODY" ]]; then
            info "Ответ сервера: ${RESPONSE_BODY}"
        fi
    else
        warn "Не удалось отправить данные на endpoint (HTTP ${HTTP_CODE})"
        if [[ -n "$RESPONSE_BODY" ]]; then
            warn "Ответ сервера: ${RESPONSE_BODY}"
        fi
    fi
}

# ==================== Создание backup архива проекта ====================
create_project_backup() {
    if [[ "$CREATE_BACKUP" != true ]]; then
        return
    fi

    info "Создаю backup архив проекта..."

    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local BACKUP_PATH="/tmp/${SLUG}_${TIMESTAMP}.zip"

    ensure_packages zip

    info "Архивирую ${PROJECT_DIR} в ${BACKUP_PATH}..."
    cd "$(dirname "${PROJECT_DIR}")" || error "Не удалось перейти в родительскую директорию"

    if zip -r -q "${BACKUP_PATH}" "$(basename "${PROJECT_DIR}")"; then
        local BACKUP_SIZE
        BACKUP_SIZE=$(du -h "${BACKUP_PATH}" | cut -f1)
        BACKUP_FILE_PATH="${BACKUP_PATH}"
        success "Backup архив успешно создан: ${BACKUP_PATH}"
        info "Размер архива: ${BACKUP_SIZE}"

        info "Сохраняю путь к backup архиву в .env файл..."
        {
            echo ""
            echo "# Backup Archive"
            echo "BACKUP_ARCHIVE_PATH=${BACKUP_PATH}"
        } >> "${PROJECT_DIR}/.env"
    else
        error "Не удалось создать backup архив"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Вывод итоговой информации ====================
print_summary() {
    echo ""
    echo "============================================================"
    info "Развёртывание завершено!"
    echo "============================================================"
    echo ""
    echo "ПРОЕКТ:"
    echo "  Slug:           ${SLUG}"
    echo "  Domain:         ${DOMAIN}"
    echo "  Type:           ${APP_TYPE}"
    echo "  Laravel:        ^${LARAVEL_VERSION}"
    echo "  DB Type:        ${DB_TYPE}$([[ "$DB_NATIVE" == true ]] && echo " (нативная)")"
    echo "  Project Path:   ${WWW_DIR}/${SLUG}"
    echo "  .env:           ${WWW_DIR}/${SLUG}/.env"
    echo ""
    echo "ПОРТЫ:"
    echo "  HTTP:           ${PORT_HTTP}"
    echo "  HTTPS:          ${PORT_HTTPS}"
    echo "  PHP-FPM:        ${PORT_PHP}"
    echo "  Redis:          ${PORT_REDIS}"
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "  MySQL:          ${PORT_MYSQL}"
    else
        echo "  PostgreSQL:     ${PORT_POSTGRES}"
    fi
    echo ""
    echo "REDIS:"
    echo "  Password:       ${REDIS_PASSWORD}"
    echo ""
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "MYSQL:"
        echo "  Database:       ${DB_MYSQL_NAME}"
        echo "  User:           ${DB_MYSQL_USER}"
        echo "  Password:       ${DB_MYSQL_PASSWORD}"
        echo "  Root Password:  ${DB_MYSQL_ROOT_PASSWORD}"
    else
        echo "POSTGRESQL:"
        echo "  Database:       ${DB_POSTGRES_NAME}"
        echo "  User:           ${DB_POSTGRES_USER}"
        echo "  Password:       ${DB_POSTGRES_PASSWORD}"
    fi
    echo ""
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        echo "HTTP BASIC AUTHENTICATION:"
        echo "  User:           ${AUTH_USER}"
        echo "  Password:       ${AUTH_PASSWORD}"
        echo "  .htpasswd:      ${WWW_DIR}/${SLUG}/.config/nginx/.htpasswd"
        echo ""
    fi
    if [[ "$INSTALL_FILAMENT" == true ]]; then
        echo "FILAMENT:"
        echo "  URL:            https://${DOMAIN}/admin"
        echo "  Name:           ${FILAMENT_NAME}"
        echo "  Email:          ${FILAMENT_EMAIL}"
        echo "  Password:       ${FILAMENT_PASSWORD}"
        echo ""
    fi
    echo "============================================================"
    echo "Следующие шаги:"
    echo "============================================================"
    if [[ "$OBTAIN_SSL" == true ]]; then
        echo "  1. Перезапустите прокси для применения SSL-сертификата:"
        echo "       cd ${PROXY_DIR} && docker compose restart"
        echo ""
        echo "  2. Проверьте доступность сайта:"
        echo "       https://${DOMAIN}"
    else
        echo "  1. Перезапустите прокси:"
        echo "       cd ${PROXY_DIR} && docker compose up -d && docker restart nginxproxy"
        echo ""
        echo "  2. Получите SSL-сертификат вручную:"
        echo "       cd ${WWW_DIR}/${SLUG} && docker compose run --rm certbot certonly \\"
        echo "         --webroot -w /var/www/certbot -d ${DOMAIN} \\"
        echo "         --email YOUR_EMAIL --agree-tos --non-interactive"
    fi
    echo ""
    echo "  Проверьте статус контейнеров:"
    echo "       cd ${WWW_DIR}/${SLUG} && docker compose ps"
    echo ""

    if [[ -n "$BACKUP_FILE_PATH" ]]; then
        echo "BACKUP:"
        echo "  Архив проекта: ${BACKUP_FILE_PATH}"
        echo ""
    fi

    echo "============================================================"
    echo ""
}

# ==================== MAIN ==================================
main() {
    local ARG
    for ARG in "$@"; do
        case "$ARG" in -h|--help) usage; exit 0 ;; esac
    done

    check_root
    ensure_www_dir
    info "Парсинг аргументов..."
    parse_args "$@"
    assign_ports
    info "Аргументы успешно обработаны"
    install_docker
    init_nginxproxy
    create_dhparam
    create_project
    update_proxy_nginx_conf
    update_proxy_docker_compose
    comment_ssl_blocks
    create_native_database
    build_and_start_project
    install_laravel
    configure_laravel_env
    install_filament
    restart_nginxproxy
    obtain_ssl_certificate
    send_project_data
    create_project_backup
    print_summary
}

main "$@"
