# Build context: this directory. Application code/configuration is supplied separately.
FROM composer:2.10.3@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac AS composer
FROM php:8.3.36-fpm-bookworm@sha256:a1a4f6f48c2e27f4974ea21459ca6c483bd3d4fbe18579ae61571a78bbe59fff AS build
COPY security-policy.php /usr/local/share/laraship/security-policy.php
RUN php /usr/local/share/laraship/security-policy.php
COPY build-extensions.sh /usr/local/src/laraship-build-extensions
RUN /bin/bash /usr/local/src/laraship-build-extensions \
    mbstring zip exif pcntl ctype xml intl pdo mysqli pdo_mysql pgsql pdo_pgsql gd bcmath sockets

# A clean runtime avoids carrying compiler/header packages from the PHP build image.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS runtime
COPY --from=build /runtime-packages.txt /tmp/runtime-packages.txt
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client openssl zip unzip libfcgi-bin \
        $(cat /tmp/runtime-packages.txt); \
    rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt; \
    groupadd -g 1000 www; \
    useradd -u 1000 -m -s /bin/bash -g www www; \
    mkdir -p /var/www/html; \
    chown -R www:www /var/www
COPY --from=build /usr/local/bin/php /usr/local/bin/php
COPY --from=build /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=build /usr/local/bin/docker-php-entrypoint /usr/local/bin/docker-php-entrypoint
COPY --from=build /usr/local/etc/php/ /usr/local/etc/php/
COPY --from=build /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY --from=build /usr/local/etc/php-fpm.d/ /usr/local/etc/php-fpm.d/
COPY --from=build /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=build /usr/local/share/laraship/security-policy.php /usr/local/share/laraship/security-policy.php
COPY --from=composer /usr/bin/composer /usr/bin/composer
COPY fpm-healthcheck.sh /usr/local/bin/fpm-healthcheck
ENV PHP_INI_DIR=/usr/local/etc/php
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i 's/^expose_php = On/expose_php = Off/' "$PHP_INI_DIR/php.ini" \
    && printf '[global]\nprocess_control_timeout = 10s\n[www]\nping.path = /_laraship/fpm-ping\nping.response = pong\n' > /usr/local/etc/php-fpm.d/zz-laraship-runtime.conf \
    && chmod 755 /usr/local/bin/fpm-healthcheck \
    && php /usr/local/share/laraship/security-policy.php
WORKDIR /var/www/html
USER 1000:1000
EXPOSE 9000
STOPSIGNAL SIGQUIT
ENTRYPOINT ["docker-php-entrypoint"]
CMD ["php-fpm"]
