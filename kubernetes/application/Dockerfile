# syntax=docker/dockerfile:1
# Build context: an existing Laravel application with a committed composer.lock.
FROM composer:2.10.3@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac AS composer
FROM php:8.3.36-apache-bookworm@sha256:96f820bf68a6e443521586cdd29b9efa1b990df6105b0f8c5524a49492752676 AS base
COPY <<'LARASHIP_SECURITY_POLICY' /usr/local/share/laraship/security-policy.php
<?php
// Mandatory runtime floors. Keep the standalone Kubernetes Dockerfile copy in sync.
function laraship_check_php(string $version): void
{
    $minimums = ['8.2' => '8.2.35', '8.3' => '8.3.36', '8.4' => '8.4.27', '8.5' => '8.5.12'];
    if (!preg_match('/^(\d+)\.(\d+)\.(\d+)$/D', $version, $parts)) {
        throw new RuntimeException('PHP must have a stable major.minor.patch version');
    }
    $branch = $parts[1] . '.' . $parts[2];
    if (!isset($minimums[$branch]) || version_compare($version, $minimums[$branch], '<')) {
        throw new RuntimeException('PHP security policy requires 8.2.35+, 8.3.36+, 8.4.27+ or 8.5.12+ in those branches; PHP 8.1 and older and unreviewed branches are forbidden');
    }
}

function laraship_check_laravel(string $version): void
{
    // Retain the existing stronger Laravel 12 floor; never restore retired releases.
    if (!preg_match('/^v?\d+\.\d+\.\d+$/D', $version)
        || version_compare(ltrim($version, 'v'), '12.0.0', '<')) {
        throw new RuntimeException('Minimum supported Laravel version: 12.0; Laravel below 10 is forbidden and retired Laravel 10/11 remain unsupported');
    }
}

function laraship_check_lock(string $path): void
{
    if (!is_file($path) || !is_readable($path)) {
        throw new RuntimeException('A readable composer.lock is required to verify the Laravel security policy');
    }
    $lock = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
    foreach (($lock['packages'] ?? []) as $package) {
        if (($package['name'] ?? '') === 'laravel/framework') {
            laraship_check_laravel($package['version'] ?? '');
            return;
        }
    }
    throw new RuntimeException('composer.lock must contain a supported laravel/framework production dependency');
}

function laraship_security_main(array $arguments): void
{
    try {
        laraship_check_php(PHP_VERSION);
        if (isset($arguments[0]) && $arguments[0] !== '') {
            laraship_check_lock($arguments[0]);
        }
    } catch (Throwable $error) {
        fwrite(STDERR, 'LaraShip security policy: ' . $error->getMessage() . PHP_EOL);
        exit(1);
    }
}

if (isset($_SERVER['SCRIPT_FILENAME']) && realpath($_SERVER['SCRIPT_FILENAME']) === __FILE__) {
    laraship_security_main(array_slice($argv, 1));
}
LARASHIP_SECURITY_POLICY
RUN php /usr/local/share/laraship/security-policy.php
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libpq-dev libzip-dev libicu-dev libonig-dev unzip \
    && docker-php-ext-install -j2 pdo_pgsql pdo_mysql zip intl mbstring bcmath pcntl opcache \
    && pecl install redis-6.2.0 && docker-php-ext-enable redis \
    && rm -rf /var/lib/apt/lists/* \
    && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && printf 'expose_php=Off\nlog_errors=On\nerror_log=/proc/self/fd/2\n' > "$PHP_INI_DIR/conf.d/zz-production.ini"
FROM base AS tooling
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
FROM tooling AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# A context bind is not committed to layers. Exclude credentials even if the caller
# forgets .dockerignore; do not persist a workstation's vendor or generated caches.
RUN --mount=type=bind,target=/src \
    tar -C /src --exclude='.git' --exclude='.env*' --exclude='auth.json' \
      --exclude='*.pem' --exclude='*.key' --exclude='id_rsa*' --exclude='id_ed25519*' \
      --exclude='vendor' --exclude='node_modules' --exclude='storage/logs/*' \
      --exclude='bootstrap/cache/*.php' -cf - . | tar -C /app -xf -
RUN test -f composer.lock && test -f artisan \
    && php /usr/local/share/laraship/security-policy.php /app/composer.lock \
    && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction \
      --prefer-dist --no-progress --no-scripts --no-plugins --optimize-autoloader
FROM base AS runtime
WORKDIR /app
COPY --from=build --chown=1000:1000 /app /app
RUN usermod -u 1000 www-data && groupmod -g 1000 www-data \
    && a2enmod rewrite \
    && sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's|/var/run/apache2|/tmp/apache|g; s|/var/lock/apache2|/tmp/apache|g' /etc/apache2/envvars \
    && sed -i 's|ErrorLog ${APACHE_LOG_DIR}/error.log|ErrorLog /proc/self/fd/2|' /etc/apache2/apache2.conf \
    && printf '%s\n' \
      'ServerName localhost' \
      'PidFile /tmp/apache.pid' \
      '<VirtualHost *:8080>' \
      '  DocumentRoot /app/public' \
      '  ErrorLog /proc/self/fd/2' \
      '  CustomLog /proc/self/fd/1 combined' \
      '  Alias /_laraship/live /usr/local/share/laraship-live' \
      '  <Directory /usr/local/share>' '    Require all granted' '  </Directory>' \
      '  <Directory /app/public>' '    AllowOverride All' '    Require all granted' '  </Directory>' \
      '</VirtualHost>' > /etc/apache2/sites-available/000-default.conf \
    && printf 'ok\n' > /usr/local/share/laraship-live \
    && printf '%s\n' '#!/bin/sh' 'set -eu' \
      'mkdir -p /tmp/apache /app/bootstrap/cache /app/storage/app /app/storage/logs /app/storage/framework/cache/data /app/storage/framework/sessions /app/storage/framework/views' \
      'export APACHE_RUN_DIR=/tmp/apache APACHE_LOCK_DIR=/tmp/apache APACHE_PID_FILE=/tmp/apache.pid' \
      'php artisan package:discover --no-interaction >&2' \
      'if [ "$1" = apache2-foreground ]; then' \
      '  "$@" & pid=$!' \
      '  trap '\''kill -WINCH "$pid" 2>/dev/null || true; wait "$pid"; exit $? '\'' TERM INT' \
      '  wait "$pid"' \
      'else' '  exec "$@"' 'fi' > /usr/local/bin/laravel-entrypoint \
    && chmod 755 /usr/local/bin/laravel-entrypoint
USER 1000:1000
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["laravel-entrypoint"]
CMD ["apache2-foreground"]
