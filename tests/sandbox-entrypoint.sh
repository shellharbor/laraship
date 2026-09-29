#!/usr/bin/env bash
# Точка входа песочницы: поднимает внутренний dockerd, копирует репозиторий и
# запускает выбранный набор тестов.
#   unit  — shellcheck + static.bats + validation.bats (быстро, без Docker-деплоя)
#   e2e   — реальное развёртывание и жизненный цикл (долго, качает образы)
#   all   — unit, затем e2e
set -euo pipefail

MODE="${1:-unit}"
SRC=/repo
WORK=/opt/laravel-deploy

start_dockerd() {
    dockerd >/var/log/dockerd.log 2>&1 &
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "dockerd не запустился:" >&2
    tail -n 30 /var/log/dockerd.log >&2
    exit 1
}

# Кэш-volume хранит контейнеры прошлых прогонов (nginxproxy с restart: always).
# При старте демона они оживают и создают пустые bind-mount каталоги в /var/www,
# из-за чего скрипт пропускает инициализацию nginxproxy. Начинаем с чистого листа,
# сохраняя только образы (кэш сборки).
reset_state() {
    docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network prune -f >/dev/null 2>&1 || true
    docker volume prune -af >/dev/null 2>&1 || true
    rm -rf /var/www
}

run_unit() {
    echo "==> shellcheck"
    # SC2155 (declare and assign separately) — стилистика в remove.sh, известна и исключена.
    (cd "${WORK}" && shellcheck -S warning -e SC2155 deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh)
    echo "==> bats: static + validation"
    bats --print-output-on-failure "${WORK}/tests/static.bats" "${WORK}/tests/validation.bats"
}

run_e2e() {
    echo "==> bats: e2e (db=${E2E_DB:-postgres}, filament=${E2E_FILAMENT:-1}, laravel=${E2E_LARAVEL:-default})"
    E2E_ALLOW=1 bats --print-output-on-failure "${WORK}/tests/e2e.bats"
}

cp -r "${SRC}" "${WORK}"
find "${WORK}" -name '*.sh' -exec chmod +x {} +
start_dockerd
reset_state

case "${MODE}" in
    unit) run_unit ;;
    e2e)  run_e2e ;;
    all)  run_unit; run_e2e ;;
    *)    echo "режим: unit | e2e | all" >&2; exit 2 ;;
esac
