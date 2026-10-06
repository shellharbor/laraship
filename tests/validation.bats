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

@test "Laravel below the minimum (12.0)" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 9.0
    assert_rejected "Minimum supported Laravel version"
}

@test "invalid Laravel version format" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 12
    assert_rejected "Invalid Laravel version format"
}

@test "invalid --php-upload-max" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --php-upload-max lots
    assert_rejected "Invalid --php-upload-max value"
}

@test "--repo: credentials inside the URL are refused (user:password@)" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://user:secret@github.com/o/r.git"
    assert_rejected "must not contain credentials"
}

@test "--repo: credentials inside the URL are refused (token@)" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://ghp_token@github.com/o/r.git"
    assert_rejected "must not contain credentials"
}

@test "--repo: unsupported URL" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "ftp://example.com/r.git"
    assert_rejected "Unsupported --repo URL"
}

@test "--repo: invalid branch" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://github.com/o/r.git" --branch "bad branch;rm"
    assert_rejected "Invalid --branch"
}

@test "--repo cannot be combined with --install-filament" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://github.com/o/r.git" \
        --install-filament --filament-email a@b.test
    assert_rejected "cannot be combined with --repo"
}

@test "--repo cannot be combined with --laravel-version" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://github.com/o/r.git" --laravel-version 12.0
    assert_rejected "cannot be combined with --repo"
}

@test "--branch requires --repo" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --branch main
    assert_rejected "--branch requires --repo"
}

@test "--deploy-key requires --repo" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --deploy-key /nonexistent
    assert_rejected "--deploy-key requires --repo"
}

@test "--deploy-key: the key file must exist" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "git@github.com:o/r.git" --deploy-key /nonexistent/key
    assert_rejected "Deploy key not found"
}

@test "--deploy-key requires an SSH repository URL" {
    local key="${BATS_TEST_TMPDIR}/key"; : >"${key}"
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --repo "https://github.com/o/r.git" --deploy-key "${key}"
    assert_rejected "requires an SSH repository URL"
}

@test "--post-deploy must be a single line" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --post-deploy $'echo one\necho two'
    assert_rejected "must be a single line"
}

@test "update.sh: unknown project" {
    run timeout 30 bash "${REPO_ROOT}/update.sh" --slug does-not-exist
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Project not found"* ]]
}

@test "update.sh: a project that was not deployed with --repo is refused" {
    mkdir -p /var/www/e2e-norepo
    run timeout 30 bash "${REPO_ROOT}/update.sh" --slug e2e-norepo
    rmdir /var/www/e2e-norepo
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"was not deployed with deploy-laravel.sh --repo"* ]]
}

@test "--config: the file supplies the settings" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=oracle\nNO_SSL=true\n')"
    assert_rejected "DB type must be 'postgres' or 'mysql'"
}

@test "--config: command-line flags override the file" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=oracle\nNO_SSL=true\n')" --db-type postgres --laravel-version 9.0
    assert_rejected "Minimum supported Laravel version"
}

@test "--config: comments, blank lines, quotes, spaces and CRLF are handled" {
    run_deploy --config "$(write_config '# a comment\r\n\r\n  DOMAIN = "x.test"\r\nDB_TYPE='"'"'postgres'"'"'\r\nNO_SSL=true\r\nLARAVEL_VERSION=9.0\r\n')"
    assert_rejected "Minimum supported Laravel version"
}

@test "--config: a true boolean turns the flag on" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=true\nINSTALL_FILAMENT=true\n')"
    assert_rejected "--filament-email is required"
}

@test "--config: a false boolean leaves the flag off" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=true\nINSTALL_FILAMENT=false\nLARAVEL_VERSION=9.0\n')"
    assert_rejected "Minimum supported Laravel version"
}

@test "--config: NO_SSL=false requires --ssl-email" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=false\n')"
    assert_rejected "--ssl-email is required"
}

@test "--config: an empty value is ignored (the slug is generated)" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=true\nSLUG=\nLARAVEL_VERSION=9.0\n')"
    [[ "${output}" == *"Generated slug:"* ]]
}

@test "--config: an invalid boolean value" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=maybe\n')"
    assert_rejected "Invalid value for NO_SSL"
}

@test "--config: an unknown key" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nFOO=1\n')"
    assert_rejected "Unknown key FOO"
}

@test "--config: the compatibility flag --type is not a config key" {
    run_deploy --config "$(write_config 'TYPE=laravel\n')"
    assert_rejected "Unknown key TYPE"
}

@test "--config: a line that is not KEY=VALUE" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\njust some words\n')"
    assert_rejected "Invalid line 2"
}

@test "--config: a missing file" {
    run_deploy --config /nonexistent/deploy.conf
    assert_rejected "Config file not found"
}

@test "--config: requires a file" {
    run_deploy --config
    assert_rejected "--config requires a file"
}

@test "--config: can be given only once" {
    local f; f="$(write_config 'DOMAIN=x.test\n')"
    run_deploy --config "${f}" --config "${f}"
    assert_rejected "--config can be given only once"
}

@test "--config: a file readable by others triggers a warning" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=oracle\n' 644)"
    [[ "${output}" == *"accessible to other users"* ]]
}

@test "versions.env: LARAVEL_VERSION is the default Laravel version" {
    run_deploy_from "$(versions_dir 'LARAVEL_VERSION=9.0\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Minimum supported Laravel version: 12.0, got: 9.0"
}

@test "Laravel 10.x and 11.x are refused up front, with the reason" {
    for v in 10.0 10.5 11.0 11.31; do
        run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version "${v}"
        assert_rejected "Minimum supported Laravel version: 12.0, got: ${v}"
        [[ "${output}" == *"no longer supported"* ]]
        [[ "${output}" == *"security advisories"* ]]
    done
}

@test "Laravel 12.0 and newer are accepted by the version check" {
    # 12.0 and 13.5 pass the check, so the run stops at the missing template folder of a bare copy
    local dir; dir="$(versions_dir 'LARAVEL_VERSION=13.0\n')"
    run_deploy_from "${dir}" --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 12.0
    assert_rejected "Template directory not found"
    run_deploy_from "${dir}" --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 13.5
    assert_rejected "Template directory not found"
}

@test "versions.env: LARAVEL_MIN_VERSION raises the minimum" {
    run_deploy_from "$(versions_dir 'LARAVEL_MIN_VERSION=13.0\n')" --slug okslug --domain x.test --db-type postgres --no-ssl --laravel-version 12.0
    assert_rejected "Minimum supported Laravel version: 13.0, got: 12.0"
}

@test "versions.env: an invalid LARAVEL_MIN_VERSION" {
    run_deploy_from "$(versions_dir 'LARAVEL_MIN_VERSION=abc\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Invalid LARAVEL_MIN_VERSION in versions.env"
}

@test "versions.env: --laravel-version overrides it" {
    # 12.0 passes the version checks, so the run stops at the missing template folder of the copy
    run_deploy_from "$(versions_dir 'LARAVEL_VERSION=9.0\n')" --domain x.test --db-type postgres --no-ssl --laravel-version 12.0
    assert_rejected "Template directory not found"
}

@test "versions.env: an invalid Laravel version" {
    run_deploy_from "$(versions_dir 'LARAVEL_VERSION=abc\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Invalid LARAVEL_VERSION in versions.env"
}

@test "versions.env: an invalid Filament constraint" {
    run_deploy_from "$(versions_dir 'FILAMENT_VERSION=^5.0;rm -rf\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Invalid FILAMENT_VERSION in versions.env"
}

@test "versions.env: an invalid image" {
    run_deploy_from "$(versions_dir 'POSTGRES_IMAGE=no tag\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Invalid POSTGRES_IMAGE in versions.env"
}

@test "versions.env: an unknown key" {
    run_deploy_from "$(versions_dir 'FOO=1\n')" --domain x.test --db-type postgres --no-ssl
    assert_rejected "Unknown key in versions.env: FOO"
}

@test "--with: an unknown module" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with nonexistent
    assert_rejected "Unknown module: nonexistent"
}

@test "--with: an invalid module name" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with "Bad Name"
    assert_rejected "Invalid module name"
}

@test "--with: a path is not a module name" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with "../deploy-laravel"
    assert_rejected "Invalid module name"
}

@test "--with filament needs --filament-email, like --install-filament" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with filament
    assert_rejected "--filament-email is required"
}

@test "--with horizon cannot be combined with the queue worker" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with horizon --queue-worker
    assert_rejected "either --with horizon or --with queue"
}

@test "--with horizon cannot be combined with --repo" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with horizon --repo "https://github.com/o/r.git"
    assert_rejected "cannot be combined with --repo"
}

@test "--with horizon enables the redis module it requires" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with horizon --laravel-version 9.0
    [[ "${output}" == *"Module horizon requires redis: enabling it"* ]]
}

@test "--config: WITH selects modules" {
    run_deploy --config "$(write_config 'DOMAIN=x.test\nDB_TYPE=postgres\nNO_SSL=true\nWITH=filament\n')"
    assert_rejected "--filament-email is required"
}

@test "--with backup: an invalid --backup-keep" {
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with backup --backup-keep 0
    assert_rejected "Invalid --backup-keep value"
    run_deploy --slug okslug --domain x.test --db-type postgres --no-ssl --with backup --backup-keep abc
    assert_rejected "Invalid --backup-keep value"
}

@test "backup.sh: an action and --slug are required" {
    run timeout 30 bash "${REPO_ROOT}/backup.sh"
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"--slug is required"* ]]
    run timeout 30 bash "${REPO_ROOT}/backup.sh" --slug x
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"An action is required"* ]]
}

@test "backup.sh: unknown project" {
    run timeout 30 bash "${REPO_ROOT}/backup.sh" --slug does-not-exist now
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Project not found"* ]]
}

@test "backup.sh: a project deployed without the backup module is refused" {
    mkdir -p /var/www/e2e-nobackup
    run timeout 30 bash "${REPO_ROOT}/backup.sh" --slug e2e-nobackup now
    rmdir /var/www/e2e-nobackup
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"was not deployed with the backup module"* ]]
}

@test "backup.sh: restore needs a dump file" {
    run timeout 30 bash "${REPO_ROOT}/backup.sh" --slug x restore
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"restore needs a dump file"* ]]
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
