FROM php:8.2-fpm


RUN apt update && apt install -y \
    libzip-dev libpng-dev libjpeg-dev libfreetype6-dev \
    libonig-dev libicu-dev libpq-dev libwebp-dev git \
    libxml2-dev

RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp

RUN docker-php-ext-install \
    mbstring \
    zip \
    exif \
    pcntl \
    ctype \
    xml \
    intl \
    pdo \
    mysqli \
    pdo_mysql \
    pgsql \
    pdo_pgsql \
    gd \
    bcmath \
    sockets \
    dom \
    soap

RUN docker-php-ext-enable mysqli pdo_mysql pgsql pdo_pgsql

RUN pecl install redis apcu && \
    docker-php-ext-enable redis apcu

RUN apt clean && rm -rf /var/lib/apt/lists/*

RUN apt update && apt install -y \
    build-essential \
    mc nano vim \
    zip unzip libzip-dev \
    openssl wget curl libcurl4-openssl-dev net-tools \
    sendmail mailutils \
    libfreetype6-dev libpng-dev libjpeg62-turbo-dev libjpeg-dev libgd-dev \
    jpegoptim optipng pngquant gifsicle \
    locales \
    git \
    libonig-dev aspell \
    ghostscript \
    clamav \
    apache2-utils \
    libbz2-dev \
    libkrb5-dev \
    libmcrypt-dev libssl-dev \
    libreadline-dev libxslt1-dev zlib1g-dev \
    python3-dev python3-psycopg2 \
    libpq-dev libfcgi-dev \
    gnupg ca-certificates \
    htop tree jq \
    supervisor procps \
    grep sed gawk \
    telnet netcat-openbsd \
    valgrind \
    bzip2 xz-utils \
    lsof strace \
    webp libwebp-dev \
    fontconfig fonts-dejavu-core \
    libicu-dev \
    && apt clean && rm -rf /var/lib/apt/lists/*

# Composer for the composer service in docker-compose.yml
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

RUN groupadd -g 1000 www \
    && useradd -u 1000 -ms /bin/bash -g www www \
    && chown -R www:www /var/www

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i 's/^expose_php = On/expose_php = Off/' "$PHP_INI_DIR/php.ini"

USER www

CMD ["php-fpm"]
