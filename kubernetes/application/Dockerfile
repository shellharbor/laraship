# syntax=docker/dockerfile:1
# Build context: an existing Laravel application with a committed composer.lock.
FROM composer:2.10.3 AS composer
FROM php:8.3.35-apache-bookworm AS base
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libpq-dev libzip-dev libicu-dev libonig-dev unzip \
    && docker-php-ext-install -j2 pdo_pgsql pdo_mysql zip intl mbstring bcmath pcntl opcache \
    && pecl install redis-6.2.0 && docker-php-ext-enable redis \
    && rm -rf /var/lib/apt/lists/* \
    && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && printf 'expose_php=Off\nlog_errors=On\nerror_log=/proc/self/fd/2\n' > "$PHP_INI_DIR/conf.d/zz-production.ini"
FROM base AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
# A context bind is not committed to layers. Exclude credentials even if the caller
# forgets .dockerignore; do not persist a workstation's vendor or generated caches.
RUN --mount=type=bind,target=/src \
    tar -C /src --exclude='.git' --exclude='.env*' --exclude='auth.json' \
      --exclude='*.pem' --exclude='*.key' --exclude='id_rsa*' --exclude='id_ed25519*' \
      --exclude='vendor' --exclude='node_modules' --exclude='storage/logs/*' \
      --exclude='bootstrap/cache/*.php' -cf - . | tar -C /app -xf -
RUN test -f composer.lock && test -f artisan \
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
