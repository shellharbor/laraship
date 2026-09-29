#!/usr/bin/env bats
# Argument validation: the script must refuse before any change to the system.
# Root is required because check_root runs before parse_args.

load helpers

setup() { require_root; }

@test "no --domain" {
    run_deploy --db-type postgres --no-ssl
    assert_rejected "--domain is not specified"
}

@test "no --db-type" {
    run_deploy --domain x.test --no-ssl
    assert_rejected "--db-type is not specified"
}

@test "invalid --db-type" {
    run_deploy --domain x.test --db-type oracle --no-ssl
    assert_rejected "DB type must be 'postgres' or 'mysql'"
}

@test "no --ssl-email without --no-ssl" {
    run_deploy --domain x.test --db-type postgres
    assert_rejected "--ssl-email is required"
}

@test "Filament without --filament-email" {
    run_deploy --domain x.test --db-type postgres --no-ssl --install-filament
    assert_rejected "--filament-email is required"
}

@test "native MySQL without --db-root-password" {
    run_deploy --domain x.test --db-type mysql --db-native --no-ssl
    assert_rejected "--db-root-password is required"
}

@test "invalid slug" {
    run_deploy --slug "bad slug!" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Invalid slug"
}

@test "invalid domain" {
    run_deploy --slug okslug --domain "bad_domain" --db-type postgres --no-ssl
    assert_rejected "Invalid domain"
}

@test "Laravel below 10.0" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 9.0
    assert_rejected "Minimum supported Laravel version"
}

@test "invalid Laravel version format" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 12
    assert_rejected "Invalid Laravel version format"
}

@test "unknown argument" {
    run_deploy --bogus
    assert_rejected "Unknown argument"
}

@test "without --slug a slug is generated and the domain gets a prefix" {
    # Get as far as the version check to see the generated slug, then be rejected.
    run_deploy --domain x.test --db-type postgres --no-ssl --laravel-version 9.0
    [[ "${output}" == *"Generated slug:"* ]]
    [[ "${output}" == *"Domain updated:"*".x.test"* ]]
}

@test "validation errors create nothing in /var/www" {
    before="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    run_deploy --slug shouldnotexist --domain x.test --db-type oracle --no-ssl
    after="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    [ "${before}" = "${after}" ]
    [ ! -e /var/www/shouldnotexist ]
}
