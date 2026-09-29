# deploy-laravel.sh — развёртывание Laravel (+ Filament) в Docker

[English](README.md) · **Русский**

[![Lint](https://github.com/shellharbor/laraship/actions/workflows/lint.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/lint.yml)
[![Tests](https://github.com/shellharbor/laraship/actions/workflows/tests.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/tests.yml)
[![E2E](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml)
[![CodeQL](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml)

`deploy-laravel.sh` разворачивает сайт на Laravel, по желанию с админ-панелью Filament, на сервере Ubuntu. Каждый сайт живёт в своём наборе Docker-контейнеров, а трафик принимает общий reverse proxy `nginxproxy`. Скрипт сам ставит Docker, создаёт проект из шаблона `laravel/`, устанавливает Laravel, настраивает PostgreSQL или MySQL (в контейнере или нативную на хосте) и получает SSL-сертификат Let's Encrypt.

Папка `laravel-deploy` самодостаточна: в ней лежат скрипт развёртывания, шаблоны, утилиты управления, примеры и навык для Claude Code. На сервер она копируется целиком (например, в `/opt/laravel-deploy/`), а скрипты выполняются **на сервере от root**. С рабочей машины (например, Windows) к серверу подключаются по SSH.

---

## Содержание

- [Состав папки](#состав-папки)
- [Архитектура](#архитектура)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Аргументы](#аргументы)
- [Что делает скрипт](#что-делает-скрипт)
- [Файлы .env](#файлы-env)
- [Подключение к БД](#подключение-к-бд)
- [Filament](#filament)
- [Примеры](#примеры)
- [Полезные команды](#полезные-команды)
- [Управление проектом](#управление-проектом)
- [Повторный запуск](#повторный-запуск)
- [Отправка данных на endpoint](#отправка-данных-на-endpoint)
- [Безопасность](#безопасность)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [Известные ограничения](#известные-ограничения)
- [Переход со старого deploy.sh](#переход-со-старого-deploysh)
- [Обновление уже развёрнутого сервера](#обновление-уже-развёрнутого-сервера)
- [Тесты и CI](#тесты-и-ci)

---

## Состав папки

```
laravel-deploy/
├── deploy-laravel.sh              # развёртывание Laravel (+ Filament); справка: --help
├── activate.sh                    # включить деактивированный проект
├── deactivate.sh                  # выключить проект без удаления
├── remove.sh                      # удалить проект полностью
├── list-projects.sh               # список проектов на сервере
├── laravel/                       # шаблон проекта → /var/www/<slug>
│   ├── docker-compose.yml
│   ├── .config/nginx/_site.conf
│   ├── .config/php/php.ini
│   └── .docker/                   # php/php81–83.Dockerfile, nginx/*.Dockerfile, init/postgres/01-init.sh
├── nginxproxy/                    # шаблон общего прокси → /var/www/nginxproxy
│   ├── nginx.conf
│   ├── nginx.Dockerfile
│   └── site-template.conf
├── examples/                      # готовые сценарии запуска (см. examples/README.md)
├── README.md                      # документация на английском
├── README-ru.md                   # этот файл (русская документация)
├── .gitignore
└── .claude/skills/deploy-laravel/SKILL.md   # навык для Claude Code
```

Скрипт ищет шаблоны `laravel/` и `nginxproxy/` рядом с собой, поэтому папку переносят целиком. `examples/`, `README.md` и `.claude/` на сервере не обязательны, но и не мешают.

**Утилиты не зависят от типа проекта.** `activate.sh`, `deactivate.sh`, `remove.sh` и `list-projects.sh` работают с любым проектом в `/var/www`, в том числе развёрнутым комплектами для Moodle или HTML.

**`/var/www/nginxproxy` общий для всех проектов сервера.** Он создаётся один раз из шаблона `nginxproxy/` той папки-комплекта, чей deploy-скрипт запустился на сервере первым. Шаблоны прокси во всех трёх комплектах (Laravel, Moodle, HTML) одинаковые, а существующий `/var/www/nginxproxy` скрипт не перезаписывает. Если вы правите шаблон `nginxproxy/` или утилиты в этой папке, перенесите изменение и в другие комплекты, чтобы копии не разошлись.

---

## Архитектура

```
/var/www/
├── nginxproxy/                     # Общий reverse proxy, единственный, кто слушает 80/443
│   ├── docker-compose.yml          # Генерируется при первом запуске; сюда добавляются сети и SSL-volumes сайтов
│   ├── nginx.conf                  # include /etc/nginx/sites/*.conf, client_max_body_size 2048m
│   ├── nginx.Dockerfile            # nginx:1.29.1-alpine
│   ├── site-template.conf          # Шаблон конфига сайта (плейсхолдеры SLUG и DOMAIN)
│   ├── dhparam.pem                 # Только при --create-dhparam
│   └── sites/
│       └── <slug>.conf             # upstream + server-блоки 80/443; после deactivate.sh — <slug>.conf.disabled
└── <slug>/                         # Проект сайта
    ├── docker-compose.yml          # Сервисы проекта, см. ниже
    ├── .env                        # Порты и пароли проекта (генерирует скрипт)
    ├── .config/
    │   ├── nginx/
    │   │   ├── _site.conf          # nginx внутри проекта (root = public_html/public)
    │   │   └── .htpasswd           # Только при --enable-basic-auth
    │   └── php/
    │       └── php.ini             # Копируется, но по умолчанию не подключён (строка в compose закомментирована)
    ├── .docker/
    │   ├── php/                    # php81/php82/php83.Dockerfile
    │   ├── nginx/                  # nginx-1.27.2/nginx-1.29.1.Dockerfile
    │   └── init/
    │       └── postgres/           # 01-init.sh — выполняется только при первой инициализации БД в контейнере
    └── public_html/                # Код Laravel (создаётся при установке)
```

Кроме файлов, у проекта есть:
- Docker-сеть `<slug>`;
- volumes `<slug>_db` (нет при `--db-native`), `<slug>_redis_data`, `<slug>_ssl_certificates` и `<slug>_certbot_www`.

### Сервисы проекта (`laravel/docker-compose.yml`)

| Сервис | Контейнер | Образ | Назначение |
|---|---|---|---|
| `php` | `<slug>_php` | `php83.Dockerfile` (PHP 8.3-FPM) | Исполняет Laravel. Порт 9000 опубликован только на `127.0.0.1:${PHP_PORT}` |
| `nginx` | `<slug>_nginx` | `nginx-1.29.1.Dockerfile` | Веб-сервер проекта, `root /var/www/html/public`. Порты `SITE_PORT_HTTP` → 80 и `SITE_PORT_HTTPS` → 443. Раз в 6 часов выполняет `nginx -s reload`, чтобы подхватить продлённый сертификат |
| `db` | `<slug>_db` | `elestio/postgres:17` или `elestio/mysql:8.0` | БД проекта. Порт `DB_PORT` хоста → 5432/3306. Шаблон содержит `db_postgres` и `db_mysql`: лишний удаляется, выбранный переименовывается в `db`. При `--db-native` удаляются оба |
| `redis` | `<slug>_redis` | `redis:7-alpine` | Redis с паролем (`--requirepass`) и AOF. Порт `REDIS_PORT` хоста → 6379 |
| `certbot` | `<slug>_certbot` | `certbot/certbot` | Выпуск сертификатов. Профиль `manual`: не стартует при `up`, запускается через `docker compose run --rm certbot ...` |
| `certbot_renew` | `<slug>_certbot_renew` | `certbot/certbot` | Каждые 12 часов выполняет `certbot renew --webroot` (цикл задан через `entrypoint`). Новый сертификат nginx подхватывает сам благодаря периодическому reload |
| `artisan` | `<slug>_artisan` | `php83.Dockerfile` | Утилита: `docker compose run --rm artisan <команда>`, работает от `www` (uid 1000) |
| `composer` | `<slug>_composer` | `php83.Dockerfile` (+ composer 2) | Утилита: `docker compose run --rm composer <команда>`. Работает в том же PHP 8.3, что и приложение, от `www` (uid 1000) и проверяет требования пакетов к PHP |
| `npm` | `<slug>_npm` | `node:current-alpine` | Утилита: `npm ...`, работает от root |
| `cron` | `<slug>_cron` | `php83.Dockerfile` | Выполняет `php artisan schedule:run` раз в 600 секунд |
| `permissions` | `<slug>_permissions` | `busybox` | Утилита: `chown 1000:1000`, права 644/755, для `storage` и `bootstrap/cache` — 775 |

Утилиты `artisan`, `composer`, `npm` и `permissions` не имеют профиля. Поэтому `docker compose up -d` тоже создаёт их контейнеры, и те сразу завершаются. Статус `Exited` у них — это нормально.

### Принцип работы

- **Отдельная сеть на проект.** Все контейнеры проекта находятся в сети `<slug>` и обращаются друг к другу по именам (`<slug>_db`, `<slug>_redis` и т.д.).
- **Единый nginxproxy на 80/443.** Контейнер `nginxproxy` подключён ко всем сетям проектов как к внешним (`external: true`). По `server_name` он проксирует HTTP на `<slug>_nginx:80`, а HTTPS — на `<slug>_nginx:443`. Сертификат сайта nginxproxy берёт из volume `<slug>_ssl_certificates`, смонтированного в `/etc/letsencrypt/<slug>`.
- **Конфиг каждого сайта лежит в отдельном файле** `nginxproxy/sites/<slug>.conf`.
- **Сертификаты подхватываются автоматически.** И nginx проекта, и `nginxproxy` (в новых установках) раз в 6 часов выполняют `nginx -s reload`. Как добавить это на сервер, развёрнутый старой версией, описано в разделе [Обновление уже развёрнутого сервера](#обновление-уже-развёрнутого-сервера).
- **Прокси общий для всего сервера.** Проекты Laravel, Moodle и HTML на одном сервере используют один `/var/www/nginxproxy` (см. [Состав папки](#состав-папки)).

---

## Требования

- **ОС:** Ubuntu 20.04+ на сервере.
- **Права:** root (`sudo`).
- **Пакеты:** `python3` (им правятся конфиги), `curl`, `ss` (iproute2). `zip` доустанавливается автоматически при `--create-backup`.
- **Docker:** если команды `docker` нет, скрипт ставит Docker CE и плагин compose из репозитория download.docker.com. Если Docker уже установлен, нужен плагин `docker compose` v2.
- **DNS:** A-запись итогового домена указывает на сервер. Без `--slug` домен превращается в `<случайный-slug>.<domain>`, поэтому нужна wildcard-запись `*.<domain>`.
- **Порты 80 и 443** свободны на сервере (их займёт nginxproxy) и доступны из интернета: Let's Encrypt проверяет домен по HTTP.
- **Доступ в интернет:** Docker Hub, packagist, npm, Let's Encrypt.
- **Для `--db-native`:** установленный и запущенный PostgreSQL или MySQL на хосте с сетевой настройкой (см. [Подключение к БД](#подключение-к-бд)).

---

## Быстрый старт

### 1. Скопируйте папку на сервер

Скопируйте папку `laravel-deploy` **целиком**, например в `/opt/laravel-deploy/`. Скрипт ищет шаблоны `laravel/` и `nginxproxy/` рядом с собой, включая скрытые `laravel/.config/` и `laravel/.docker/`. Состав папки описан в разделе [Состав папки](#состав-папки).

С рабочей машины (PowerShell или Git Bash), из каталога, где лежит `laravel-deploy`:

```bash
# если есть SSH-доступ под root
scp -r laravel-deploy root@server:/opt/

# под обычным пользователем с sudo
scp -r laravel-deploy user@server:~/
ssh user@server 'sudo rm -rf /opt/laravel-deploy && sudo mv ~/laravel-deploy /opt/'
```

Можно также вынести папку в отдельный git-репозиторий и выполнить `git clone` на сервере в `/opt/laravel-deploy`.

Если файлы прошли через Windows, проверьте окончания строк. При CRLF bash падает с ошибкой `$'\r': command not found`:

```bash
grep -c $'\r' /opt/laravel-deploy/deploy-laravel.sh      # должно быть 0
# исправление:
sudo find /opt/laravel-deploy -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.conf' -o -name '*Dockerfile' \) \
  -exec sed -i 's/\r$//' {} +
```

### 2. Запустите

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```

Порты, пароли и учётные данные БД, которые не указаны явно, генерируются автоматически. Скрипт печатает их в консоль и сохраняет в `/var/www/shop/.env`. В конце выводится итоговый блок с данными проекта и следующими шагами.

Справка по флагам (root не нужен):

```bash
bash /opt/laravel-deploy/deploy-laravel.sh --help
```

---

## Аргументы

Таблица составлена строго по `parse_args` и шапке `--help` скрипта. Неизвестный флаг даёт ошибку `Неизвестный аргумент`.

### Обязательные

| Аргумент | Значение | Описание |
|---|---|---|
| `--domain` | `DOMAIN` | Домен сайта. Допустимы символы `A-Za-z0-9.-`. Если `--slug` не указан, к домену спереди добавляется случайный slug: `example.com` → `a3f7k2m9.example.com` |
| `--db-type` | `postgres` \| `mysql` | Тип БД |
| `--ssl-email` | `EMAIL` | Email для Let's Encrypt. Обязателен, если не указан `--no-ssl` |

### Проект

| Аргумент | Значение | По умолчанию | Описание |
|---|---|---|---|
| `--slug` | `SLUG` | случайные 8 символов `a-z0-9` | Идентификатор проекта: имя папки, сети, префикс контейнеров и volumes. Формат `^[A-Za-z0-9][A-Za-z0-9_-]*$`, рекомендуются строчные буквы. Если указан, домен **не** меняется |
| `--laravel-version` | `X.Y` | `13.0` | Версия Laravel, ставится как `laravel/laravel:^X.Y`. Минимум `10.0` |
| `--create-backup` | — | выкл. | После развёртывания создать `/tmp/<slug>_<YYYYmmdd_HHMMSS>.zip` из папки проекта |
| `--endpoint` | `URL` | — | Отправить данные проекта в JSON методом PUT (см. [ниже](#отправка-данных-на-endpoint)) |
| `--type` | `laravel` | — | Только для совместимости со старым `deploy.sh`. Любое другое значение — ошибка. В новых командах не используйте |

### Filament

| Аргумент | Значение | По умолчанию | Описание |
|---|---|---|---|
| `--install-filament` | — | выкл. | Установить `filament/filament:^5.0` и панель `/admin` |
| `--filament-email` | `EMAIL` | — | Email администратора. **Обязателен** с `--install-filament`, наличие проверяется сразу при старте |
| `--filament-name` | `NAME` | 8 символов `a-f0-9` | Имя администратора |
| `--filament-password` | `PASS` | 10 символов `a-zA-Z0-9` | Пароль администратора |

### База данных

| Аргумент | Значение | По умолчанию | Описание |
|---|---|---|---|
| `--db-native` | — | выкл. | Использовать СУБД на хосте, а не контейнер `db` |
| `--db-root-password` | `PASS` | — | Root-пароль **нативной** MySQL. Обязателен при `--db-native` + `--db-type mysql`. Нигде не сохраняется |
| `--db-postgres-name` | `NAME` | генерируется | Имя БД PostgreSQL |
| `--db-postgres-user` | `USER` | генерируется | Пользователь PostgreSQL |
| `--db-postgres-password` | `PASS` | генерируется | Пароль PostgreSQL |
| `--db-mysql-name` | `NAME` | генерируется | Имя БД MySQL |
| `--db-mysql-user` | `USER` | генерируется | Пользователь MySQL |
| `--db-mysql-password` | `PASS` | генерируется | Пароль пользователя MySQL |
| `--db-mysql-root-password` | `PASS` | генерируется | Root-пароль MySQL **в контейнере** (`MYSQL_ROOT_PASSWORD`). При `--db-native` не используется |

Флаги `--db-postgres-*` учитываются только при `--db-type postgres`, флаги `--db-mysql-*` — только при `--db-type mysql`. Сгенерированные имена — это 15 символов, первый из которых буква: `[a-z][a-z0-9]{14}`. Сгенерированные пароли — 15 символов из набора `A-Za-z0-9@%_+-`.

### Порты

Порты, указанные явно, используются как есть, без проверки занятости. Остальные подбираются случайно из диапазона. Свободным считается порт, который сейчас никто не слушает по данным `ss`. Всего делается до 100 попыток.

| Аргумент | Сервис | Автодиапазон | Примечание |
|---|---|---|---|
| `--port-http` | HTTP nginx проекта | 8100–8400 | `SITE_PORT_HTTP` |
| `--port-https` | HTTPS nginx проекта | 4100–4300 | `SITE_PORT_HTTPS` |
| `--port-php` | PHP-FPM | 9100–9600 | `PHP_PORT`, публикуется только на `127.0.0.1` |
| `--port-redis` | Redis | 6500–6800 | `REDIS_PORT` |
| `--port-postgres` | PostgreSQL | 5500–5800 | С `--db-native` по умолчанию `5432` |
| `--port-mysql` | MySQL | 3400–3600 | С `--db-native` по умолчанию `3306` |

Для контейнерной БД это порт, **опубликованный на хосте**. Внутри сети проекта БД всегда слушает 5432/3306. Для нативной БД это порт СУБД на хосте, и он записывается в `DB_PORT` Laravel.

### Прочее

| Аргумент | Значение | По умолчанию | Описание |
|---|---|---|---|
| `--redis-password` | `PASS` | генерируется | Пароль Redis |
| `--create-dhparam` | — | выкл. | Создать `/var/www/nginxproxy/dhparam.pem` (2048 бит, несколько минут) и смонтировать его в nginx проекта (см. [ограничения](#известные-ограничения)) |
| `--enable-basic-auth` | — | выкл. | Включить HTTP Basic Auth в nginx проекта |
| `--auth-user` | `USER` | генерируется (15 символов) | Пользователь Basic Auth |
| `--auth-password` | `PASS` | генерируется (15 символов) | Пароль Basic Auth |
| `--no-ssl` | — | — | Не получать SSL-сертификат. Тогда `--ssl-email` не нужен |
| `--obtain-ssl` | — | вкл. | Получать сертификат. Это и так поведение по умолчанию; флаг принимается, но в `--help` не указан. Из `--no-ssl` и `--obtain-ssl` действует последний |
| `-h`, `--help` | — | — | Показать справку и выйти. Проверяется до проверки root |

---

## Что делает скрипт

Шаги перечислены в порядке вызова функций в `main()`.

| # | Функция | Что делает | При ошибке |
|---|---|---|---|
| 0 | — | Если среди аргументов есть `-h` или `--help`, печатает справку и выходит | — |
| 1 | `check_root` | Проверяет, что скрипт запущен от root | выход |
| 2 | `ensure_www_dir` | Создаёт `/var/www`, если папки нет | выход |
| 3 | `parse_args` | Разбирает флаги и проверяет их: обязательные, формат slug, домена и версии, root-пароль для нативной MySQL, `--ssl-email`, `--filament-email`. Генерирует slug (и меняет домен), пароль Redis, учётные данные БД и Basic Auth, **печатая их в консоль**. Проверяет наличие папки шаблона `laravel/` | выход |
| 4 | `assign_ports` | Подбирает свободные порты HTTP, HTTPS, PHP-FPM, Redis и БД | выход, если порт не найден |
| 5 | `install_docker` | Ставит Docker CE и compose-плагин, если команды `docker` нет | выход |
| 6 | `init_nginxproxy` | Если `/var/www/nginxproxy` нет: копирует `nginx.Dockerfile`, `nginx.conf` и `site-template.conf`, создаёт `sites/` и базовый `docker-compose.yml` (порты 80/443, `nginx -s reload` раз в 6 часов, пустые сети и volumes). Существующий `nginxproxy` не меняется | — |
| 7 | `create_dhparam` | Только с `--create-dhparam` и если `dhparam.pem` ещё нет: генерирует его через `alpine/openssl` | выход |
| 8 | `create_project` | Если `/var/www/<slug>` уже есть, останавливает контейнеры (`docker compose down`) и **удаляет папку** без подтверждения. Затем копирует шаблон `laravel/`, раскладывает Dockerfile'ы по `.docker/php`, `.docker/nginx` и создаёт `.docker/init/postgres`. Создаёт `public_html` с владельцем `1000:1000`, потому что composer работает от `www`. Заменяет `{SLUG}` в `docker-compose.yml`, настраивает сервис БД (лишний удаляет, выбранный переименовывает в `db`, при `--db-native` удаляет оба вместе с зависимостями `depends_on`). Генерирует `.env`, заменяет `MYSITE.COM` и `{SLUG}` в `_site.conf`. С `--create-dhparam` раскомментирует монтирование `dhparam.pem`. С `--enable-basic-auth` создаёт `.htpasswd` (через `httpd:alpine`), раскомментирует его монтирование и директивы `auth_basic` | выход |
| 9 | `update_proxy_nginx_conf` | Создаёт `nginxproxy/sites/<slug>.conf` из `site-template.conf`. **Если файл уже есть, пропускает шаг** | выход, если нет шаблона |
| 10 | `update_proxy_docker_compose` | Добавляет в `nginxproxy/docker-compose.yml` внешнюю сеть `<slug>` и volume `<slug>_ssl_certificates` (монтируется в `/etc/letsencrypt/<slug>`) | — |
| 11 | `comment_ssl_blocks` | Комментирует server-блок `listen 443` в `_site.conf` проекта и в `sites/<slug>.conf`, чтобы nginx стартовал без сертификата | — |
| 12 | `create_native_database` | Только с `--db-native`: создаёт пользователя и БД в системной СУБД (см. [Подключение к БД](#подключение-к-бд)) | выход, если СУБД нет, она недоступна или неверен root-пароль |
| 13 | `build_and_start_project` | Создаёт сеть `<slug>` и volumes, выполняет `docker compose up -d --build`, ждёт 10 секунд и показывает статус контейнеров | выход, если `up` не удался |
| 14 | `install_laravel` | Выполняет `docker compose run --rm composer create-project laravel/laravel:^X.Y .` (composer в образе PHP 8.3, без `--ignore-platform-reqs`), затем `docker compose run --rm permissions`. Шаг пропускается, если `public_html/artisan` уже существует | выход |
| 15 | `configure_laravel_env` | Прописывает в `public_html/.env` параметры `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` (закомментированные строки Laravel 11+ раскомментируются, строки Laravel 10 заменяются) и `APP_URL=https://<domain>`. Выполняет `artisan migrate --force` | **только предупреждение**, если миграции не прошли |
| 16 | `install_filament` | Только с `--install-filament`: `composer require filament/filament:"^5.0"`, затем `artisan filament:install --panels`, затем `artisan make:filament-user`. Учётные данные дописываются в `.env` проекта | **выход**: следующие шаги не выполняются |
| 17 | `restart_nginxproxy` | Выполняет `docker compose up -d` в `/var/www/nginxproxy`: подключает сеть проекта и при первом запуске собирает образ прокси | предупреждение |
| 18 | `obtain_ssl_certificate` | Если не указан `--no-ssl`: выполняет `certbot certonly --webroot` для домена. При успехе раскомментирует SSL-блоки, перезапускает nginx проекта и nginxproxy | **только предупреждение**, скрипт продолжает работу |
| 19 | `send_project_data` | Только с `--endpoint`: отправляет JSON методом PUT | предупреждение |
| 20 | `create_project_backup` | Только с `--create-backup`: создаёт zip папки проекта в `/tmp` и дописывает путь в `.env` | выход |
| 21 | `print_summary` | Печатает итог: проект, порты и **все пароли**, следующие шаги | — |

---

## Файлы .env

### `/var/www/<slug>/.env` — файл проекта

Его генерирует функция `write_project_env`. Шаблонного `laravel/.env` больше нет. Файл читает `docker compose` при подстановке переменных в `docker-compose.yml`. Формат для PostgreSQL:

```env
SITE_HOST=shop.example.com
SITE_PORT_HTTP=8231
SITE_PORT_HTTPS=4175

PHP_PORT=9342

REDIS_PORT=6621
REDIS_PASSWORD=<15 символов>

DB_PORT=5634
DB_POSTGRES_NAME=<15 символов>
DB_POSTGRES_USER=<15 символов>
DB_POSTGRES_PASSWORD=<15 символов>

DB_NATIVE=false
```

Для MySQL вместо блока `DB_POSTGRES_*` записывается:

```env
DB_PORT=3478
DB_MYSQL_NAME=...
DB_MYSQL_USER=...
DB_MYSQL_PASSWORD=...
DB_MYSQL_PASSWORD_ROOT=...
```

Что дописывается в файл по флагам:

```env
# с --enable-basic-auth (сразу при генерации, после DB_NATIVE)
AUTH_USER=...
AUTH_PASSWORD=...

# с --install-filament (после успешного создания пользователя)
# Filament Admin Credentials
FILAMENT_ADMIN_NAME=...
FILAMENT_ADMIN_EMAIL=...
FILAMENT_ADMIN_PASSWORD=...

# с --create-backup (в самом конце)
# Backup Archive
BACKUP_ARCHIVE_PATH=/tmp/<slug>_<YYYYmmdd_HHMMSS>.zip
```

`DB_PORT` здесь — это порт на **хосте**: опубликованный порт контейнерной БД или порт нативной СУБД. Laravel его не использует (см. [Подключение к БД](#подключение-к-бд)). Полный пример лежит в [examples/project.env.example](examples/project.env.example).

### `/var/www/<slug>/public_html/.env` — файл Laravel

Файл создаётся самим Laravel при `create-project`. Скрипт меняет в нём только эти строки:

```env
APP_URL=https://<domain>
DB_CONNECTION=pgsql            # или mysql
DB_HOST=<slug>_db              # нативная БД: 172.17.0.1
DB_PORT=5432                   # mysql: 3306; нативная БД — порт СУБД на хосте
DB_DATABASE=...
DB_USERNAME=...
DB_PASSWORD=...
```

Остальное остаётся как в стандартном `.env` Laravel, в том числе `APP_ENV=local` и `APP_DEBUG=true`. Redis в `.env` Laravel **не прописывается**. Чтобы им пользоваться и перевести сайт в production, отредактируйте файл вручную:

```env
APP_ENV=production
APP_DEBUG=false
REDIS_HOST=<slug>_redis
REDIS_PORT=6379                # внутренний порт, не REDIS_PORT из .env проекта
REDIS_PASSWORD=<REDIS_PASSWORD из /var/www/<slug>/.env>
# по желанию: CACHE_STORE=redis (Laravel 11+) / CACHE_DRIVER=redis (Laravel 10), SESSION_DRIVER=redis, QUEUE_CONNECTION=redis
```

После правки выполните `docker compose run --rm artisan config:cache`. Если стоит Filament, прочитайте про production в разделе [Filament](#filament).

---

## Подключение к БД

### Контейнерная БД (по умолчанию)

| Откуда подключаемся | Хост | Порт |
|---|---|---|
| Laravel и другие контейнеры проекта | `<slug>_db` | `5432` (PostgreSQL) / `3306` (MySQL) — внутренний |
| С хоста (psql, mysql, туннель SSH) | `127.0.0.1` | `DB_PORT` из `/var/www/<slug>/.env` — опубликованный |

Скрипт записывает в `DB_PORT` Laravel **внутренний** порт. Внешний порт внутри сети проекта не слушается. Опубликованный порт открыт на всех интерфейсах хоста (см. [Безопасность](#безопасность)).

Для PostgreSQL при **первой** инициализации пустого volume выполняется `.docker/init/postgres/01-init.sh`, который задаёт пароль пользователя (`ALTER USER`). С уже существующим volume ни этот скрипт, ни переменные `POSTGRES_*`/`MYSQL_*` пароль не меняют.

### Нативная БД (`--db-native`)

- Laravel получает `DB_HOST=172.17.0.1` (IP интерфейса `docker0` по умолчанию) и `DB_PORT` = `--port-postgres`/`--port-mysql`, по умолчанию `5432`/`3306`. Если в `/etc/docker/daemon.json` изменён `bip`, поправьте `DB_HOST` вручную.
- БД создаётся через подключение по умолчанию: `sudo -u postgres psql` или `mysql -u root -p<--db-root-password>`. Флаги портов на то, **где** создаётся БД, не влияют. Они меняют только `DB_PORT` в Laravel.
- **PostgreSQL:** `CREATE USER "<user>" WITH PASSWORD ...`, `CREATE DATABASE "<db>" OWNER "<user>"`, `GRANT ALL PRIVILEGES`. Если пользователь или БД уже существуют, выводится предупреждение, а **пароль не меняется**.
- **MySQL:** `CREATE DATABASE IF NOT EXISTS`, `CREATE USER IF NOT EXISTS '<user>'@'%'`, `GRANT ALL PRIVILEGES ON <db>.* TO '<user>'@'%'`, `FLUSH PRIVILEGES`. Хост `'%'` нужен потому, что приложение подключается из контейнера через docker bridge, а не с localhost.

**Сетевую доступность СУБД обеспечивает администратор, скрипт её не настраивает.** Контейнеры проекта находятся в сети `<slug>`, у которой своя подсеть. Узнать её:

```bash
docker network inspect <slug> -f '{{(index .IPAM.Config 0).Subnet}}'
```

- **PostgreSQL:** `listen_addresses` в `postgresql.conf` должен включать адрес, доступный из контейнеров (`172.17.0.1` или `*`). В `pg_hba.conf` нужна строка, пускающую подсеть проекта (или все docker-подсети), например `host <db> <user> 172.16.0.0/12 scram-sha-256`. После правки выполните `systemctl reload postgresql`.
- **MySQL:** проверьте `bind-address` в `/etc/mysql/mysql.conf.d/mysqld.cnf`. В Ubuntu по умолчанию там `127.0.0.1`, и контейнеры не подключатся.
- **Фаервол** (ufw/iptables) должен пропускать трафик из docker-подсетей на порт СУБД.

Проверка из контейнера: `cd /var/www/<slug> && docker compose run --rm artisan migrate:status`.

---

## Filament

С `--install-filament` (и обязательным `--filament-email`) скрипт после миграций выполняет три шага:

1. `docker compose run --rm composer require filament/filament:"^5.0"`
2. `docker compose run --rm artisan filament:install --panels`
3. `docker compose run --rm artisan make:filament-user --name=... --email=... --password=...`

Результат:
- панель администратора по адресу `https://<domain>/admin` (ID панели `admin` по умолчанию);
- провайдер панели, обычно `app/Providers/Filament/AdminPanelProvider.php`, и опубликованные ассеты Filament в `public/`;
- пользователь в таблице `users`;
- строки `FILAMENT_ADMIN_NAME`, `FILAMENT_ADMIN_EMAIL` и `FILAMENT_ADMIN_PASSWORD` в `/var/www/<slug>/.env`, а данные для входа — в выводе скрипта.

Если не заданы `--filament-name`/`--filament-password`, генерируются имя из 8 символов `a-f0-9` и пароль из 10 символов `a-zA-Z0-9`.

Важно:
- **Совместимость.** Связка Laravel 13 + Filament 5 на PHP 8.3 проверена реальным развёртыванием. Скрипт ставит Filament `^5.0` независимо от `--laravel-version`, поэтому для других версий Laravel (особенно 10.x и 11.x) проверьте совместимость по документации Filament. Composer работает в том же образе PHP 8.3, что и приложение, и проверяет требования пакетов. При несовместимости он откажет с понятной ошибкой, а не поставит пакеты под другую версию PHP.
- **Любая ошибка на этих шагах завершает скрипт.** nginxproxy не будет перезапущен, SSL не будет получен, endpoint и backup не выполнятся. Если миграции упали (это только предупреждение), `make:filament-user` тоже упадёт: таблицы `users` нет.
- **Интерактивность.** В проверочном развёртывании `filament:install --panels` прошёл без вопросов. Если установщик всё же спросит ID панели (например, в интерактивном терминале), оставьте `admin`.
- **Production.** Filament по умолчанию пускает в панель пользователей без проверки только в окружении `local`. Скрипт не меняет `APP_ENV=local`. Если вы переведёте сайт в `APP_ENV=production`, модель `User` должна реализовать `FilamentUser::canAccessPanel()`, иначе будет 403. Подробности — в разделе документации Filament о деплое в production.

---

## Примеры

Готовые скрипты с этими сценариями лежат в [examples/](examples/README.md). Они по умолчанию вызывают `deploy-laravel.sh` из своей папки `laravel-deploy`, поэтому запускаются с места: `bash /opt/laravel-deploy/examples/02-mysql-explicit-slug.sh`. В примерах используются `example.com` и фейковые пароли `ChangeMe_...`. Если папка лежит не в `/opt/laravel-deploy`, поправьте путь в командах ниже.

### 1. Минимальный: PostgreSQL, slug генерируется

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --domain example.com \
  --db-type postgres \
  --ssl-email admin@example.com
# Результат: slug вида a3f7k2m9, домен a3f7k2m9.example.com (нужна wildcard-запись *.example.com),
# Laravel ^13.0, PostgreSQL 17 в контейнере; порты и пароли сгенерированы и лежат в /var/www/a3f7k2m9/.env
```

### 2. MySQL с явным slug

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type mysql \
  --ssl-email admin@example.com
# Результат: /var/www/shop, домен shop.example.com (не меняется), MySQL 8.0 в контейнере shop_db
```

### 3. Явные учётные данные БД и порты

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug crm \
  --domain crm.example.com \
  --db-type postgres \
  --db-postgres-name crm_db \
  --db-postgres-user crm_user \
  --db-postgres-password ChangeMe_CrmDb1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8150 \
  --port-https 4150 \
  --port-php 9150 \
  --port-redis 6550 \
  --port-postgres 5550 \
  --ssl-email admin@example.com
# Результат: БД crm_db / crm_user с заданным паролем; порты хоста 8150/4150/9150/6550/5550
# (PHP-FPM 9150 — только на 127.0.0.1)
# (занятость явно заданных портов скрипт не проверяет); Laravel подключается к crm_db:5432
```

### 4. Нативный PostgreSQL

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug blog \
  --domain blog.example.com \
  --db-type postgres \
  --db-native \
  --ssl-email admin@example.com
# Результат: контейнера db нет; пользователь и БД созданы через `sudo -u postgres psql`;
# Laravel: DB_HOST=172.17.0.1, DB_PORT=5432. PostgreSQL заранее должен слушать docker-bridge,
# а pg_hba.conf должен пускать подсеть сети blog
```

### 5. Нативный MySQL

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug wiki \
  --domain wiki.example.com \
  --db-type mysql \
  --db-native \
  --db-root-password ChangeMe_MysqlRoot1 \
  --port-mysql 3306 \
  --ssl-email admin@example.com
# Результат: БД и пользователь 'user'@'%' созданы в системной MySQL; Laravel: DB_HOST=172.17.0.1, DB_PORT=3306.
# Root-пароль нигде не сохраняется: для remove.sh передайте его снова через --db-root-password.
# bind-address MySQL должен пускать подключения из контейнеров
```

### 6. Filament с автогенерацией имени и пароля

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug cms \
  --domain cms.example.com \
  --db-type postgres \
  --install-filament \
  --filament-email admin@example.com \
  --ssl-email admin@example.com
# Результат: панель https://cms.example.com/admin; имя (8 hex) и пароль (10 символов) выведены в консоль
# и дописаны в /var/www/cms/.env как FILAMENT_ADMIN_*
```

### 7. Filament с явными данными администратора

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug backoffice \
  --domain backoffice.example.com \
  --db-type mysql \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --ssl-email admin@example.com
# Результат: панель https://backoffice.example.com/admin, вход admin@example.com / ChangeMe_Filament1
```

### 8. Basic Auth (закрытый стенд)

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug staging \
  --domain staging.example.com \
  --db-type postgres \
  --enable-basic-auth \
  --auth-user staging \
  --auth-password ChangeMe_Staging1 \
  --ssl-email admin@example.com
# Результат: .config/nginx/.htpasswd, auth_basic в location / HTTPS-блока nginx проекта;
# AUTH_USER/AUTH_PASSWORD в .env. Запросы к /index.php защиту обходят (см. ограничения)
```

### 9. Без SSL (`--no-ssl`)

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug preview \
  --domain preview.example.com \
  --db-type postgres \
  --no-ssl
# Результат: проект и контейнеры созданы, но HTTPS-блоки закомментированы; по HTTP отдаётся только ACME-challenge,
# поэтому сайт откроется после ручного получения сертификата (см. «SSL не получен» в Troubleshooting)
```

### 10. Production: полный набор + endpoint + backup

```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug app \
  --domain app.example.com \
  --laravel-version 13.0 \
  --db-type postgres \
  --db-postgres-name app_prod \
  --db-postgres-user app_prod \
  --db-postgres-password ChangeMe_PgProd1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8200 \
  --port-https 4200 \
  --port-php 9200 \
  --port-redis 6600 \
  --port-postgres 5600 \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --endpoint https://api.example.com/deployments \
  --create-backup \
  --ssl-email admin@example.com
# Результат: сайт https://app.example.com с Filament; JSON с данными проекта отправлен PUT-запросом
# на endpoint; архив /tmp/app_<дата>.zip (путь в BACKUP_ARCHIVE_PATH).
# После развёртывания вручную: APP_ENV=production, APP_DEBUG=false, закрыть фаерволом порты HTTP/HTTPS проекта,
# Redis и БД (PHP-FPM уже только на 127.0.0.1)
```

---

## Полезные команды

Все команды выполняются из папки проекта: `cd /var/www/<slug>`.

```bash
# Статус и логи
docker compose ps                     # работающие контейнеры
docker compose ps -a                  # включая завершившиеся утилиты
docker compose logs -f --tail=100 nginx php
docker compose logs --tail=100 db

# Artisan (контейнер работает от пользователя www, uid 1000)
docker compose run --rm artisan migrate --force
docker compose run --rm artisan migrate:status
docker compose run --rm artisan optimize:clear
docker compose run --rm artisan config:cache
docker compose run --rm artisan storage:link
docker compose run --rm artisan tinker
docker compose run --rm artisan make:filament-user     # ещё один администратор Filament

# Composer (в образе PHP 8.3, от www, uid 1000)
docker compose run --rm composer install --no-dev --optimize-autoloader
docker compose run --rm composer require vendor/package

# npm (работает от root, после него выполните permissions)
docker compose run --rm npm install
docker compose run --rm npm run build

# Права на файлы
docker compose run --rm permissions

# Сертификаты (продление — certbot_renew раз в 12 ч, reload nginx — автоматически раз в 6 ч)
docker compose run --rm certbot certificates
docker compose run --rm certbot renew --dry-run
docker compose logs --tail=20 certbot_renew
docker exec nginxproxy nginx -s reload && docker compose exec nginx nginx -s reload   # подхватить сертификат сразу, не дожидаясь reload

# Проверка конфигов nginx
docker compose exec nginx nginx -t
docker exec nginxproxy nginx -t

# Консоль БД (контейнерная)
docker compose exec db psql -U <DB_POSTGRES_USER> -d <DB_POSTGRES_NAME>
docker compose exec db mysql -u <DB_MYSQL_USER> -p <DB_MYSQL_NAME>

# Пересборка после правки docker-compose.yml или Dockerfile
docker compose up -d --build
```

### Docker: контейнеры, прокси, сети, volumes

```bash
# Контейнеры
docker ps -a --filter "name=<slug>_"                 # контейнеры проекта
docker logs <container_name> --tail 50               # логи; -f — следить в реальном времени
docker restart <container_name>                      # также stop / start

# Все контейнеры проекта
cd /var/www/<slug> && docker compose restart
cd /var/www/<slug> && docker compose down
cd /var/www/<slug> && docker compose up -d
cd /var/www/<slug> && docker compose up -d --build   # с пересборкой

# Прокси (общий для всех проектов сервера)
cd /var/www/nginxproxy && docker compose up -d && docker restart nginxproxy
docker exec nginxproxy nginx -t                      # проверка конфигурации
docker logs nginxproxy --tail 50

# Сети и volumes
docker network ls
docker network inspect <slug>
docker volume ls --filter "name=<slug>_"
docker volume inspect <volume_name>

# Очистка и мониторинг
docker container prune          # остановленные контейнеры (завершившиеся утилиты создадутся заново при следующем up)
docker image prune              # неиспользуемые образы
docker volume prune             # неиспользуемые volumes; осторожно: с --all удаляются и именованные, включая данные БД
docker stats                    # ресурсы контейнеров
docker system df                # место на диске
```

---

## Управление проектом

Утилиты лежат в папке `laravel-deploy` рядом с `deploy-laravel.sh`, требуют root и работают с `/var/www`. От типа проекта они **не зависят**: ими можно управлять любым проектом на сервере, в том числе Moodle или HTML, развёрнутым другим комплектом. Slug во всех утилитах сравнивается точно: `lms` не задевает `lms2`.

### `list-projects.sh` — список проектов

```bash
sudo bash /opt/laravel-deploy/list-projects.sh
```

Скрипт показывает каждую папку `/var/www/*`, в которой есть `docker-compose.yml` (кроме `nginxproxy`). Для каждой выводятся домен (`SITE_HOST`), статус контейнеров (RUNNING/STOPPED), наличие SSL-сертификата (проверяется `live/<домен>/fullchain.pem` в volume `<slug>_ssl_certificates`), тип и порт БД, порты HTTP, HTTPS и PHP, первые 5 контейнеров и подсказки команд. В конце — статус nginxproxy и число конфигов в `sites/`.

### `deactivate.sh` — выключить без удаления

```bash
sudo bash /opt/laravel-deploy/deactivate.sh --slug <slug>
```

Шаги скрипта:
1. выполняет `docker compose down` в папке проекта;
2. переименовывает `nginxproxy/sites/<slug>.conf` в `<slug>.conf.disabled`, иначе nginx прокси не смог бы разрешить upstream `<slug>_nginx` и перестал бы запускаться для всех сайтов;
3. комментирует строки `<slug>` (сеть и SSL-volume) в `nginxproxy/docker-compose.yml`;
4. делает `docker restart nginxproxy`.

Данные, volumes и папка проекта сохраняются.

### `activate.sh` — включить обратно

```bash
sudo bash /opt/laravel-deploy/activate.sh --slug <slug>
```

Шаги скрипта:
1. выполняет `docker compose up -d --build` в проекте;
2. возвращает `<slug>.conf.disabled` → `<slug>.conf`;
3. раскомментирует строки `<slug>` в `nginxproxy/docker-compose.yml`;
4. перезапускает существующие сервисы `php` и `nginx` проекта;
5. выполняет `docker compose up -d` в nginxproxy, чтобы прокси заново подключился к сети проекта, и затем `docker restart nginxproxy`.

### `remove.sh` — полное удаление

```bash
sudo bash /opt/laravel-deploy/remove.sh --slug <slug> --domain <домен>
# проект с нативной MySQL: root-пароль нужен, чтобы удалить её БД и пользователя
sudo bash /opt/laravel-deploy/remove.sh --slug <slug> --domain <домен> --db-root-password '<root-пароль>'
```

`--slug` и `--domain` обязательны, причём `--domain` используется только в сообщениях. Скрипт выводит предупреждение и **просит ввести `yes`**; любой другой ответ отменяет удаление. После подтверждения шаги идут так:

1. удаляет сеть и SSL-volume `<slug>` из `nginxproxy/docker-compose.yml`;
2. удаляет `nginxproxy/sites/<slug>.conf` и `<slug>.conf.disabled`;
3. выполняет `docker compose up -d` в nginxproxy;
4. выполняет `docker compose down` в проекте;
5. удаляет volumes `<slug>_*`, перечисленные в `docker-compose.yml` проекта, в том числе **данные БД**;
6. удаляет сеть `<slug>`;
7. делает `docker restart nginxproxy`;
8. удаляет нативную БД, но только если в `.env` проекта стоит `DB_NATIVE=true`. Контейнерная БД этим шагом не трогается.
   - PostgreSQL: `DROP DATABASE` и `DROP USER` через `sudo -u postgres psql`.
   - MySQL: `DROP DATABASE` и `DROP USER '<user>'@'%', '<user>'@'localhost'`, если передан `--db-root-password`. Без пароля скрипт только печатает SQL для ручного удаления.
9. удаляет backup-архив из `BACKUP_ARCHIVE_PATH`;
10. удаляет `/var/www/<slug>`.

**Действие необратимо.**

---

## Повторный запуск

Если `/var/www/<slug>` уже существует, скрипт **без подтверждения**:
1. ищет контейнеры `<slug>_*` и, если какие-то запущены, выполняет `docker compose down` (без `-v`);
2. **удаляет папку `/var/www/<slug>` целиком**: код в `public_html`, оба `.env` и `.htpasswd`;
3. создаёт проект заново и ставит Laravel с нуля.

При этом **остаются**:
- Docker volumes `<slug>_db`, `<slug>_redis_data`, `<slug>_ssl_certificates` и `<slug>_certbot_www`. PostgreSQL и MySQL с непустым volume не применяют новые `POSTGRES_*`/`MYSQL_*`, а `01-init.sh` не выполняется. Поэтому **новые сгенерированные пароли к существующей БД не подходят**: миграции упадут с предупреждением, а `make:filament-user` завершит скрипт.
- Файл `nginxproxy/sites/<slug>.conf`: он не перегенерируется, так что при смене домена с тем же slug в прокси останется старый домен.
- Для нативной БД — существующие пользователь и БД. Их пароль не меняется.

Рекомендации:
- **Чистая переустановка:** сначала `remove.sh --slug <slug> --domain <домен>` (для нативной MySQL ещё `--db-root-password`), затем `deploy-laravel.sh`.
- **Нужно сохранить данные БД:** до повторного запуска скопируйте `/var/www/<slug>/.env` и передайте прежние учётные данные явно (`--db-postgres-name/-user/-password` или `--db-mysql-*`, при желании `--redis-password`). Код в `public_html` всё равно будет удалён, поэтому сохраните его заранее (`--create-backup` или `tar`).

---

## Отправка данных на endpoint

С `--endpoint URL` после попытки получить SSL (и до backup) скрипт выполняет:

```bash
curl -X PUT -H "Content-Type: application/json" -d '<JSON>' URL
```

Тело запроса (значения фейковые; файл-пример — [examples/endpoint-payload.json](examples/endpoint-payload.json)):

```json
{
  "slug": "app",
  "domain": "app.example.com",
  "app_type": "laravel",
  "laravel_version": "13.0",
  "db_type": "postgres",
  "ports": {
    "http": 8231,
    "https": 4175,
    "php": 9342,
    "redis": 6621
  },
  "redis": {
    "password": "ChangeMe_Redis1"
  },
  "database": {
    "type": "postgres",
    "port": 5634,
    "name": "exampledbname01",
    "user": "exampledbuser01",
    "password": "ChangeMe_DbPwd1"
  },
  "basic_auth": {
    "enabled": true,
    "user": "exampleauthuser",
    "password": "ChangeMe_Auth01"
  },
  "ssl": {
    "enabled": true,
    "email": "admin@example.com"
  },
  "project_path": "/var/www/app"
}
```

Особенности:
- `database.port` — порт на хосте (как `DB_PORT` в `.env` проекта).
- `ssl.enabled` отражает флаг (`--no-ssl` или нет), а не то, получен ли сертификат на самом деле.
- Без Basic Auth поля `basic_auth.user` и `basic_auth.password` — пустые строки.
- Данных Filament, признака нативной БД и root-паролей в JSON нет.
- Значения не экранируются. Явные пароли с `"` или `\` сломают JSON.
- Ответ, отличный от 2xx, даёт только предупреждение. В запросе все пароли открытым текстом, поэтому используйте только HTTPS-endpoint.

---

## Безопасность

- **Генерация секретов.** Используется `/dev/urandom`. Пароли — 15 символов из `A-Za-z0-9@%_+-`: из набора исключены символы, ломающие `sed`, `.env` и docker compose (`& | / \ $ # =` и кавычки). Имена БД, пользователей и логин Basic Auth — 15 символов `[a-z][a-z0-9]{14}`. Пароль Filament — всего 10 символов `a-zA-Z0-9`, так что для production лучше задать свой. Явные пароли тоже составляйте из `A-Za-z0-9@%_+-`: значения пишутся в `.env` без кавычек.
- **Где лежат секреты.** Скрипт печатает сгенерированные значения в консоль при генерации и все пароли в итоговом блоке. Учитывайте это при записи сессии и логах CI. На диске секреты лежат в открытом виде в `/var/www/<slug>/.env` и `public_html/.env`. Скрипт не меняет права этих файлов, поэтому рекомендуется `chmod 600 /var/www/<slug>/.env`. `--db-root-password` передаётся в командной строке, так что остаётся в истории shell и виден в `ps` во время работы.
- **Опубликованные порты.** PHP-FPM публикуется только на `127.0.0.1:${PHP_PORT}`, потому что у FastCGI нет аутентификации. Порты HTTP/HTTPS nginx проекта, Redis и контейнерной БД по-прежнему открыты на всех интерфейсах хоста (`0.0.0.0`). Redis и БД защищены только паролями. Docker пишет свои правила iptables в обход ufw. Снаружи должны быть открыты только 80/443. Закройте остальные порты облачным фаерволом или правилами в цепочке `DOCKER-USER`, либо привяжите их к `127.0.0.1` в `docker-compose.yml` проекта.
- **Laravel по умолчанию.** Остаются `APP_ENV=local` и `APP_DEBUG=true`, а в PHP-образе включён xdebug. Для production переключите окружение (см. [Файлы .env](#файлы-env)).
- **TLS.** На nginx проекта включены TLS 1.2/1.3 и HSTS. Редирект HTTP→HTTPS не включён, но по HTTP приложение и не отдаётся.
- **Basic Auth** — это дополнительный барьер, а не полноценная защита: см. [ограничения](#известные-ограничения).

---

## Troubleshooting / FAQ

### Миграции упали («Не удалось выполнить миграции Laravel»)

Это только предупреждение, скрипт продолжает работу. Но если стоит `--install-filament`, он завершится на `make:filament-user`. Возможные причины:
- БД не успела инициализироваться: скрипт ждёт после `up` всего 10 секунд, а первая инициализация MySQL бывает дольше;
- после повторного запуска остался старый volume с другим паролем (см. [Повторный запуск](#повторный-запуск));
- нативная СУБД недоступна из контейнера.

```bash
cd /var/www/<slug>
docker compose logs --tail=50 db
grep '^DB_' public_html/.env
docker compose run --rm artisan migrate --force
```

Если Filament после этого не установился, выполните три его команды вручную (см. [Filament](#filament)), затем перезапустите прокси (`cd /var/www/nginxproxy && docker compose up -d`) и получите SSL, как описано ниже.

### SSL не получен

При ошибке certbot скрипт выводит предупреждение и **продолжает работу**. SSL-блоки в `_site.conf` и `sites/<slug>.conf` остаются закомментированными, так что сайт недоступен ни по HTTPS, ни по HTTP (по HTTP отдаётся только ACME-challenge). Проверьте:
- A-запись домена указывает на сервер. Для автоматического slug нужна запись `*.<domain>`.
- Порты 80/443 открыты, nginxproxy запущен, `curl -I http://<домен>/.well-known/acme-challenge/test` доходит до сервера (ответ 404 от nginx — это нормально).
- Не превышены лимиты Let's Encrypt.

После исправления:

```bash
cd /var/www/<slug>
docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
  -d <домен> --email <email> --agree-tos --non-interactive

# Раскомментировать SSL-блоки: скрипт добавил ровно один '#' в начало каждой строки блока
sed -i '/^#server {/,/^#}/ s/^#//' .config/nginx/_site.conf /var/www/nginxproxy/sites/<slug>.conf

docker compose exec nginx nginx -t && docker compose restart nginx
cd /var/www/nginxproxy && docker compose restart
```

Этот же порядок действий подходит после `--no-ssl`.

### nginxproxy не стартует или перезапускается по кругу

Смотрите `docker logs --tail=50 nginxproxy` и `cd /var/www/nginxproxy && docker compose up -d`:
- **`address already in use` на 80/443** — порт занят другим веб-сервером на хосте (`sudo ss -tlnp | grep -E ':(80|443) '`).
- **`host not found in upstream "<slug>_nginx..."`** — в `sites/` лежит `*.conf` проекта, чьи контейнеры не работают: не поднялись при развёртывании, остановлены вручную без `deactivate.sh` или удалены не через `remove.sh`. Запустите проект, выключите его через `deactivate.sh` или переименуйте конфиг в `<slug>.conf.disabled`.
- **`network <slug> declared as external, but could not be found`** — развёртывание прервалось после шага 10, до создания сети (например, на нативной БД). Повторите развёртывание или удалите записи `<slug>` из `nginxproxy/docker-compose.yml` и `sites/<slug>.conf`.
- **Ошибка в сертификате** — SSL-блок раскомментирован, а сертификата нет. Проверьте `docker compose run --rm certbot certificates` в проекте.

### Права на storage, 500 Internal Server Error

PHP-FPM, `artisan` и `composer` работают от пользователя `www` (uid 1000). `npm` и команды, запущенные на хосте от root, создают файлы с владельцем root. Скрипт выполняет `permissions` после установки Laravel. Если файлы оказались чужими (например, после `npm` или копирования от root), выполните:

```bash
cd /var/www/<slug> && docker compose run --rm permissions
docker compose logs --tail=50 php
tail -n 50 public_html/storage/logs/laravel.log
```

### Composer: «requires php ...» / пакет несовместим с версией PHP

Composer работает в том же образе PHP 8.3, что и приложение, и проверяет требования пакетов к PHP. Если `create-project` или `composer require` отказываются из-за версии PHP, у вас два пути:
- выбрать совместимые версии (`--laravel-version`, версию пакета);
- поменять версию PHP у проекта (см. ниже).

Не обходите проверку флагом `--ignore-platform-reqs`. Именно так старая версия скрипта ставила пакеты под чужой PHP, и приложение падало с `syntax error`.

### Большие загрузки файлов (413, «файл слишком большой»)

Действуют три лимита, и срабатывает наименьший:
- `nginxproxy`: `client_max_body_size 2048m`;
- nginx проекта (`_site.conf`): `client_max_body_size 900M`;
- PHP. Файл `.config/php/php.ini` проекта по умолчанию **не подключён**, поэтому работают стандартные `upload_max_filesize = 2M` и `post_max_size = 8M`.

Чтобы разрешить большие загрузки:
1. поднимите эти значения в `.config/php/php.ini`;
2. раскомментируйте у сервиса `php` строку `- ./.config/php/php.ini:/usr/local/etc/php/php.ini:ro`;
3. выполните `docker compose up -d php`.

Серверы, развёрнутые старой версией, без правки `nginx.conf` прокси режут загрузки больше 1 МБ (см. [Обновление уже развёрнутого сервера](#обновление-уже-развёрнутого-сервера)).

### Прочее

- **502 Bad Gateway.** Контейнер `<slug>_php` не работает: смотрите `docker compose ps` и `docker compose logs php`.
- **`http://домен` отдаёт 404.** Так задумано: HTTP-блок nginx проекта обслуживает только `/.well-known/acme-challenge/`, строка `return 301` закомментирована. Работайте по `https://`.
- **Сертификат продлён, но браузер видит старый.** nginx проекта и `nginxproxy` перечитывают сертификаты сами раз в 6 часов. Чтобы применить новый сертификат сразу, выполните `docker exec nginxproxy nginx -s reload` и `docker compose exec nginx nginx -s reload`. На серверах, развёрнутых старой версией, периодического reload нет, пока вы не выполните шаги из раздела [Обновление уже развёрнутого сервера](#обновление-уже-развёрнутого-сервера). Журнал продления: `docker compose logs certbot_renew`.
- **Порт занят после активации старого проекта.** Автоподбор учитывает только порты, которые слушаются сейчас. Порты остановленных проектов могут быть выданы новому. Если есть деактивированные проекты, задавайте порты явно.
- **Задачи планировщика выполняются нерегулярно.** `cron` вызывает `schedule:run` раз в 10 минут. Поменяйте `sleep 600` на `sleep 60` в `docker-compose.yml` проекта и выполните `docker compose up -d cron`.
- **Как сменить версию PHP.** Поменяйте `dockerfile: php83.Dockerfile` у сервисов `php`, `artisan`, `composer` и `cron` на `php81.Dockerfile` или `php82.Dockerfile` и выполните `docker compose up -d --build`. Composer встроен во все три Dockerfile.

---

## Известные ограничения

- **Basic Auth не закрывает PHP-location.** `auth_basic` включается только в `location /` HTTPS-блока `_site.conf`. Запрос прямо к `/index.php` (в том числе `/index.php/<маршрут>`) попадает в `location ~ [^/]\.php(/|$)`, где `auth_basic` нет, и обходит защиту.
- **Root-пароль нативной MySQL не сохраняется.** `--db-root-password` нигде не записывается, поэтому для удаления такой БД передайте его `remove.sh` ещё раз. Строка `Root Password` в итоговом выводе и `DB_MYSQL_PASSWORD_ROOT` в `.env` при `--db-native` содержат случайное значение, а не root-пароль системной MySQL.
- **`--create-dhparam` почти ни на что не влияет.** Файл создаётся и монтируется в nginx проекта, но в шаблоне `_site.conf` нет строки `#ssl_dhparam`, так что директива не включается. nginxproxy, который терминирует TLS для клиентов, этот файл не использует. Для эффекта добавьте `ssl_dhparam` вручную.
- **Планировщик и очереди.** `cron` вызывает `schedule:run` раз в 10 минут, а не каждую минуту. Воркера очередей (`queue:work`) нет.
- **PHP фиксирован на 8.3.** Скрипт не выбирает PHP под `--laravel-version`. Если выбранная версия Laravel или пакет требуют другой PHP, composer откажет, и версию PHP придётся поменять вручную (см. [Troubleshooting](#troubleshooting--faq)).
- **Лимит загрузок PHP** — 2M/8M по умолчанию, потому что `php.ini` проекта не подключён (см. [Troubleshooting](#troubleshooting--faq)).
- **HTTP.** Приложение по HTTP не обслуживается, редиректа на HTTPS нет. С `--no-ssl` сайт недоступен, пока сертификат не получен вручную.
- **Повторный запуск** удаляет папку проекта без подтверждения и не обновляет существующий `sites/<slug>.conf` (см. [Повторный запуск](#повторный-запуск)).
- **Спецсимволы в явных значениях** (`$`, `#`, пробелы, кавычки, `\`) могут сломать `.env` проекта (его читает docker compose), `.env` Laravel или JSON для endpoint.
- **Порты HTTP/HTTPS проекта, Redis и БД открыты на всех интерфейсах** (PHP-FPM — только на `127.0.0.1`), см. [Безопасность](#безопасность).
- **Laravel по умолчанию:** `APP_ENV=local`, `APP_DEBUG=true`, в PHP-образе включён xdebug (см. [Безопасность](#безопасность)).
- **Backup** — это zip папки `/var/www/<slug>` в `/tmp`. Данных БД из Docker volume и сертификатов в нём нет, а `/tmp` может очищаться при перезагрузке.

---

## Переход со старого deploy.sh

Общий `deploy.sh --type <тип>` заменён отдельными комплектами; для Laravel это папка `laravel-deploy` со скриптом `deploy-laravel.sh`. Флаги остались прежними: поменяйте путь к скрипту и уберите `--type`.

```bash
# Было
sudo bash deploy.sh --type laravel --domain example.com --db-type postgres --ssl-email admin@example.com
# Стало
sudo bash /opt/laravel-deploy/deploy-laravel.sh --domain example.com --db-type postgres --ssl-email admin@example.com
```

Для совместимости `--type laravel` принимается и игнорируется. С другим значением скрипт завершится с подсказкой, какой `deploy-<тип>.sh` нужен.

Что изменилось для Laravel по сравнению со старым скриптом (проверено реальным развёртыванием: Laravel 13 + PostgreSQL + Filament 5 + Basic Auth):

- **Laravel не устанавливался на актуальных версиях.** Composer запускался в образе `composer:latest` (PHP 8.5) с `--ignore-platform-reqs` и ставил пакеты под PHP 8.4+. Приложение работает на PHP 8.3, поэтому Symfony падал с `syntax error`, а вместе с ним миграции и Filament. Теперь composer работает в том же PHP-образе, что и приложение, от пользователя `www`. Контейнер `cron` переведён с PHP 8.2 на 8.3.
- **SSL-сертификаты не продлевались.** `certbot_renew` крутился в цикле перезапусков (`certbot sh -c …`), а сигнал nginx на перечитывание сертификата не доходил. Теперь продление работает, а nginx проекта и `nginxproxy` сами перечитывают конфигурацию раз в 6 часов.
- **PHP-FPM был открыт наружу** (`0.0.0.0:<PHP_PORT>`, FastCGI без аутентификации). Теперь он публикуется только на `127.0.0.1`.
- **Загрузки больше 1 МБ** отклонялись прокси с ошибкой 413. В `nginxproxy/nginx.conf` добавлен `client_max_body_size 2048m`.
- **Подключение к контейнерной БД.** В `.env` Laravel попадал порт, опубликованный на хосте (например, 5623), хотя внутри Docker-сети БД слушает 5432/3306, и миграции падали. Теперь используется внутренний порт.
- **Нативная MySQL.** Пользователь создаётся как `'user'@'%'`: с `'localhost'` контейнер подключиться не мог.
- **Laravel 10.** DB-параметры в `.env` прописываются и тогда, когда они не закомментированы.
- **Пароли** генерируются без символов, ломающих `sed`, `.env` и compose (`&`, `$`, `/`, `=` и т.п.). Пользовательские значения экранируются при записи в `.env` Laravel.
- **Неудача certbot** больше не обрывает скрипт: развёртывание завершается, SSL-блоки остаются закомментированными.
- **Путь к `dhparam.pem`** в compose проекта исправлен (`../../nginxproxy` → `../nginxproxy`).
- **`.env` проекта** генерируется скриптом, шаблонный `laravel/.env` больше не нужен.
- **Новые и изменённые флаги.** Добавлены `--port-php`, `--port-redis` и `--help`. `--port-postgres`/`--port-mysql` учитываются и для контейнерной БД. `--filament-email` проверяется сразу при старте.
- **Slug с дефисом** (`my-site`) при повторном развёртывании больше не дублирует записи в compose прокси.

Утилиты управления тоже исправлены:

- `deactivate.sh` больше не роняет `nginxproxy`, а с ним и все сайты: конфиг сайта отключается переименованием в `.conf.disabled`.
- `activate.sh` возвращает конфиг, перезапускает только существующие сервисы `php`/`nginx` и заново подключает прокси к сети проекта.
- `remove.sh` исправлен в нескольких местах:
  - не падает на MySQL-проектах;
  - не путает контейнерную БД с нативной (раньше мог выполнить `DROP DATABASE` в системном PostgreSQL);
  - удаляет пользователя нативной MySQL `'user'@'%'`;
  - принимает `--db-root-password` и удаляет `.conf.disabled`.
- `activate.sh`, `deactivate.sh` и `remove.sh` сравнивают slug точно: `lms` больше не задевает `lms2`.
- `list-projects.sh` правильно показывает наличие SSL: сертификат ищется в docker volume.

---

## Обновление уже развёрнутого сервера

Скрипт не перезаписывает существующий `/var/www/nginxproxy` и уже созданные проекты. Чтобы получить исправления на сервере, развёрнутом старой версией, выполните шаги ниже. Пути к шаблонам даны для `/opt/laravel-deploy`.

**1. Общий прокси.** Шаг выполняется один раз на сервер и затрагивает все сайты.
- В `/var/www/nginxproxy/nginx.conf` добавьте в блок `http { … }` строку `client_max_body_size 2048m;`.
- В `/var/www/nginxproxy/docker-compose.yml` добавьте сервису `nginxproxy` периодическое перечитывание сертификатов:
  ```yaml
      command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
  ```
- Примените изменения: `cd /var/www/nginxproxy && docker compose up -d`. Прокси пересоздаётся, сайты недоступны несколько секунд.

**2. Каждый Laravel-проект** (`/var/www/<slug>/docker-compose.yml`). Образец — `laravel/docker-compose.yml` в этой папке; `{SLUG}` в нём замените на slug проекта.
- `php`: порт `"${PHP_PORT}:9000"` → `"127.0.0.1:${PHP_PORT}:9000"`.
- `nginx`: добавьте ту же строку `command:`, что и у прокси в шаге 1.
- `certbot_renew`: замените `command: >` на `entrypoint: >`. Строку с `docker kill --signal=HUP` можно удалить, она не работает.
- `composer`: замените сервис вариантом из шаблона (сборка из `php83.Dockerfile`, `entrypoint: [ 'composer' ]`, без `--ignore-platform-reqs`).
- `cron`: `dockerfile: php82.Dockerfile` → `php83.Dockerfile`.
- Скопируйте обновлённые Dockerfile'ы с встроенным composer:
  ```bash
  cp /opt/laravel-deploy/laravel/.docker/php/php8*.Dockerfile /var/www/<slug>/.docker/php/
  cd /var/www/<slug> && docker compose up -d --build
  ```

**3. Если приложение уже сломано** пакетами, поставленными старым composer под чужой PHP (`syntax error` в `vendor/`), пересоберите зависимости под PHP 8.3. Старый composer работал от root, поэтому сначала верните файлы пользователю `www`:
```bash
cd /var/www/<slug>
docker compose run --rm permissions
docker compose run --rm composer update      # composer.lock обновится под PHP 8.3
docker compose run --rm artisan migrate --force
```

---

## Тесты и CI

В папке `tests/` лежит набор автотестов на [bats](https://github.com/bats-core/bats-core). Он проверяет, что скрипт работает штатно и что созданный сайт соответствует переданным аргументам.

| Набор | Что проверяет | Нужно | Время |
|---|---|---|---|
| `static.bats` | синтаксис `bash -n`, отсутствие CRLF, shebang, наличие шаблонов, `--help`, что каждый флаг из `parse_args` описан в справке | только bash | секунды |
| `validation.bats` | 13 сценариев неверных аргументов: скрипт обязан отказать (`exit 1`) с понятным сообщением **до** любых изменений в системе | root | секунды |
| `e2e.bats` | реальное развёртывание: контейнеры, порты, `.env`, версия Laravel, БД и миграции, Redis, Basic Auth, Filament (админ и пароль), HTTP-ответы приложения, backup; затем `list-projects`, `deactivate`, `activate`, `remove` (удаляет контейнеры, volumes, сеть, конфиг прокси и папку) | root, Docker, интернет | 10–20 минут |

### Локальный запуск

Нужен только Docker. Тесты идут в изолированной песочнице (Ubuntu со своим Docker-демоном), Docker хоста они не затрагивают:

```bash
bash tests/run-local.sh                                    # unit: shellcheck + static + validation
bash tests/run-local.sh e2e                                # реальный деплой: PostgreSQL + Filament
E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e    # MySQL, без Filament
bash tests/run-local.sh all
```

Параметры e2e задаются переменными окружения: `E2E_DB` (`postgres`|`mysql`), `E2E_FILAMENT` (`1`|`0`), `E2E_LARAVEL` (например `12.0`; пусто — версия по умолчанию), `E2E_SSL` (`1` — запросить сертификат без DNS и проверить, что скрипт только предупреждает). Кэш образов песочницы лежит в volume `laravel-deploy-tests-docker`.

> **Не запускайте `tests/e2e.bats` на живом сервере.** Он пишет в `/var/www`, занимает порты 80/443 и создаёт Docker-ресурсы. Без `E2E_ALLOW=1` тест сам откажется стартовать.

### GitHub Actions

Workflow-файлы лежат в `.github/workflows/`:

| Workflow | Что делает | Когда |
|---|---|---|
| `lint.yml` | `bash -n`, проверка CRLF, ShellCheck, actionlint | push, PR |
| `tests.yml` | `static.bats` и `validation.bats` | push, PR |
| `e2e.yml` | `e2e.bats` на чистом раннере, матрица: PostgreSQL + Filament (Laravel 12) и MySQL (версия по умолчанию) | push и PR при изменении скриптов, шаблонов или тестов; по понедельникам; вручную |
| `codeql.yml` | CodeQL-анализ самих workflow-файлов (язык `actions`) | push, PR, раз в неделю |

CodeQL не поддерживает Bash, поэтому он проверяет только GitHub Actions, а сами скрипты покрывают ShellCheck и тесты. Запрос сертификата Let's Encrypt (`E2E_SSL=1`) в CI выполняется только по расписанию и вручную, чтобы не упираться в лимиты на каждый PR. Обновления версий actions предлагает Dependabot (`.github/dependabot.yml`).

Бейджи вверху файла указывают на репозиторий `shellharbor/laraship`; при переименовании или форке замените путь во всех четырёх ссылках.
