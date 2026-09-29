#!/usr/bin/env bats
# Валидация аргументов: скрипт обязан отказать до любых изменений в системе.
# Нужен root, потому что check_root выполняется раньше parse_args.

load helpers

setup() { require_root; }

@test "нет --domain" {
    run_deploy --db-type postgres --no-ssl
    assert_rejected "Не указан --domain"
}

@test "нет --db-type" {
    run_deploy --domain x.test --no-ssl
    assert_rejected "Не указан --db-type"
}

@test "неверный --db-type" {
    run_deploy --domain x.test --db-type oracle --no-ssl
    assert_rejected "Тип БД должен быть 'postgres' или 'mysql'"
}

@test "нет --ssl-email без --no-ssl" {
    run_deploy --domain x.test --db-type postgres
    assert_rejected "необходимо указать --ssl-email"
}

@test "Filament без --filament-email" {
    run_deploy --domain x.test --db-type postgres --no-ssl --install-filament
    assert_rejected "необходимо указать --filament-email"
}

@test "нативная MySQL без --db-root-password" {
    run_deploy --domain x.test --db-type mysql --db-native --no-ssl
    assert_rejected "необходимо указать --db-root-password"
}

@test "недопустимый slug" {
    run_deploy --slug "bad slug!" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Недопустимый slug"
}

@test "недопустимый домен" {
    run_deploy --slug okslug --domain "bad_domain" --db-type postgres --no-ssl
    assert_rejected "Недопустимый домен"
}

@test "Laravel ниже 10.0" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 9.0
    assert_rejected "Минимальная поддерживаемая версия Laravel"
}

@test "неверный формат версии Laravel" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 12
    assert_rejected "Неверный формат версии Laravel"
}

@test "неизвестный аргумент" {
    run_deploy --bogus
    assert_rejected "Неизвестный аргумент"
}

@test "без --slug slug генерируется, а домен получает префикс" {
    # Доходим до проверки версии, чтобы увидеть сгенерированный slug, и отказываем.
    run_deploy --domain x.test --db-type postgres --no-ssl --laravel-version 9.0
    [[ "${output}" == *"Сгенерирован slug:"* ]]
    [[ "${output}" == *"Обновлён домен:"*".x.test"* ]]
}

@test "ошибки валидации ничего не создают в /var/www" {
    before="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    run_deploy --slug shouldnotexist --domain x.test --db-type oracle --no-ssl
    after="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    [ "${before}" = "${after}" ]
    [ ! -e /var/www/shouldnotexist ]
}
