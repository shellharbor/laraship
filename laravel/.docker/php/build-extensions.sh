#!/bin/bash
# Shared builder only: pinned PECL sources and the ELF runtime dependency closure.
set -euo pipefail

REDIS_VERSION=6.3.0
REDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
APCU_VERSION=5.1.28
APCU_SHA256=ca9c1820810a168786f8048a4c3f8c9e3fd941407ad1553259fb2e30b5f057bf

apt-get update
# PHPIZE_DEPS is the trusted upstream space-separated package list.
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PHPIZE_DEPS \
    libzip-dev libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    libonig-dev libicu-dev libpq-dev libwebp-dev libxml2-dev
docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp
docker-php-ext-install -j2 "$@"

curl --disable --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
    -fsSL "https://pecl.php.net/get/redis-${REDIS_VERSION}.tgz" -o /tmp/redis.tgz
curl --disable --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
    -fsSL "https://pecl.php.net/get/apcu-${APCU_VERSION}.tgz" -o /tmp/apcu.tgz
printf '%s  /tmp/redis.tgz\n%s  /tmp/apcu.tgz\n' "$REDIS_SHA256" "$APCU_SHA256" | sha256sum -c -
pecl install /tmp/redis.tgz /tmp/apcu.tgz
docker-php-ext-enable redis apcu

# Resolve actual shared libraries into Debian runtime packages. Headers and compilers
# are never copied into the runtime, and matching Bookworm libraries supply the ABI.
{
    ldd /usr/local/bin/php /usr/local/sbin/php-fpm
    find /usr/local/lib/php/extensions -name '*.so' -exec ldd '{}' ';'
} | awk '/=> \// { path=$3; sub("^/(usr/)?", "", path); print "*" path }' | sort -u > /tmp/runtime-libraries.txt
xargs -r dpkg-query --search < /tmp/runtime-libraries.txt | cut -d: -f1 | sort -u > /runtime-packages.txt
test -s /runtime-packages.txt
rm -rf /var/lib/apt/lists/* /tmp/pear /tmp/redis.tgz /tmp/apcu.tgz /tmp/runtime-libraries.txt
