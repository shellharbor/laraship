# Общие хелперы для bats-тестов laravel-deploy.
# shellcheck shell=bash

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
DEPLOY="${REPO_ROOT}/deploy-laravel.sh"
SCRIPTS=(deploy-laravel.sh activate.sh deactivate.sh remove.sh list-projects.sh)

# Вывод скрипта без ANSI-цветов.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

require_root() {
    [ "$(id -u)" -eq 0 ] || skip "нужен root (тесты запускаются через sudo или в песочнице)"
}

# Запуск deploy-laravel.sh с жёстким таймаутом: если валидация вдруг пропустит
# неверные аргументы, скрипт не должен уйти в реальное развёртывание.
run_deploy() {
    run timeout 30 bash "${DEPLOY}" "$@"
    output="$(printf '%s' "${output}" | strip_ansi)"
}

# Ожидаем отказ на этапе валидации: код 1 и сообщение об ошибке.
assert_rejected() {
    local expected="$1"
    [ "${status}" -eq 1 ] || {
        echo "ожидался exit=1, получен ${status}" >&2
        echo "${output}" >&2
        return 1
    }
    [[ "${output}" == *"${expected}"* ]] || {
        echo "в выводе нет «${expected}»" >&2
        echo "${output}" >&2
        return 1
    }
}
