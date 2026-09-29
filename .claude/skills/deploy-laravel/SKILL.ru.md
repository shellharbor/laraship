---
name: deploy-laravel
description: Применяй, когда нужно развернуть Laravel или Laravel+Filament сайт на Ubuntu-сервере через deploy-laravel.sh (Docker, общий nginxproxy, SSL Let's Encrypt, PostgreSQL/MySQL в контейнере или нативная БД) либо подготовить для этого команду. Также применяй для диагностики, повторного запуска, деактивации и удаления такого развёртывания.
---

# Развёртывание Laravel (+ Filament) через deploy-laravel.sh

Навык относится к самодостаточной папке `laravel-deploy` (корень проекта — три уровня выше этого файла). Полная документация: [README-ru.md](../../../README-ru.md). Готовые сценарии: [examples/](../../../examples/README.md). В README есть также переход со старого `deploy.sh` и обновление серверов, развёрнутых старой версией.
Флаги бери только из таблицы «Аргументы» в README (она сверена с `parse_args`). Не выдумывай флаги и не используй `--type` (он оставлен только для совместимости).

## Что делает скрипт

`deploy-laravel.sh` запускается на Ubuntu-сервере от root и:
- ставит Docker (если его нет) и один раз создаёт общий reverse proxy `/var/www/nginxproxy` на портах 80/443;
- создаёт проект `/var/www/<slug>` из шаблона `laravel/` с отдельной Docker-сетью `<slug>` и контейнерами php (8.3-FPM), nginx, db (PostgreSQL 17 / MySQL 8.0, без него при `--db-native`), redis, cron, certbot_renew, а также утилитами artisan, composer, npm и permissions;
- ставит Laravel (`composer create-project laravel/laravel:^X.Y`, по умолчанию 13.0) через composer в том же образе PHP 8.3 от пользователя www, прописывает БД и `APP_URL` в `public_html/.env` и выполняет миграции;
- по флагам ставит Filament 5 (панель `/admin`), включает Basic Auth, отправляет JSON на `--endpoint` и создаёт zip-архив;
- получает сертификат Let's Encrypt (webroot) и включает HTTPS-блоки nginx.

Slug, пароли, имена БД и порты, которые не заданы явно, генерируются и печатаются в консоль.

## Где выполняется

Все скрипты работают только на сервере. На локальной Windows-машине их не запускай. Работай через SSH (ssh есть и в Git Bash, и в PowerShell):

```bash
ssh user@server 'sudo bash /opt/laravel-deploy/deploy-laravel.sh --help'
```

- На сервере должна лежать папка `laravel-deploy` **целиком**, обычно это `/opt/laravel-deploy/`; уточни путь у пользователя. Скрипт ищет рядом с собой `laravel/` и `nginxproxy/`. Если папки нет, предложи скопировать её и дождись согласия: `scp -r laravel-deploy user@server:~/`, затем `sudo mv ~/laravel-deploy /opt/` (или `git clone`). Подробности — README → «Быстрый старт».
- Нужны LF-окончания строк. При CRLF bash падает с ошибкой `$'\r': command not found` (см. README → «Быстрый старт»).
- Не вводи пароли SSH или sudo за пользователя. Если без пароля не получается, отдай пользователю готовую команду, чтобы он выполнил её сам.

## Предпосылки

- Ubuntu 20.04+, root или sudo, установлены `python3`, `curl` и `ss`.
- Если Docker уже стоит, нужен плагин `docker compose` v2. Если Docker нет, скрипт поставит его сам.
- A-запись итогового домена указывает на сервер. **Без `--slug` домен станет `<случайный-slug>.<domain>`**, поэтому нужна wildcard-запись `*.<domain>`, иначе SSL не получить.
- Порты 80 и 443 на сервере свободны (их займёт nginxproxy) и открыты снаружи.
- `--db-native`: PostgreSQL или MySQL установлен и запущен на хосте и слушает адрес, доступный из контейнеров (`172.17.0.1`). В `pg_hba.conf` должны быть разрешены docker-подсети, а для MySQL нужно проверить `bind-address` (в Ubuntu по умолчанию `127.0.0.1`). Скрипт этого не настраивает, это задача администратора.

Проверка без изменений на сервере:

```bash
ssh user@server 'lsb_release -ds; python3 --version; docker --version; docker compose version; \
  ls -A /opt/laravel-deploy /opt/laravel-deploy/laravel; grep -c $'"'"'\r'"'"' /opt/laravel-deploy/deploy-laravel.sh; \
  sudo ss -tlnp | grep -E ":(80|443) "; ls /var/www; getent hosts <домен>'
```
Ожидаемо: в `/opt/laravel-deploy` есть `deploy-laravel.sh`, `laravel/` и `nginxproxy/`, в `laravel/` есть `.config` и `.docker`, счётчик CR равен `0`.

Если `/var/www/nginxproxy` уже существует, прокси общий: он мог быть создан комплектом для Moodle или HTML, и это нормально. Скрипт его не перезаписывает, а только добавляет сеть, volume и `sites/<slug>.conf`.

## Workflow

### 1. Собери параметры
Обязательные параметры: `--domain`, `--db-type postgres|mysql` и `--ssl-email EMAIL` (либо `--no-ssl`).
Обязательно уточни у пользователя:
- **slug** (`--slug`). Советуй задать его явно, строчными буквами. Без него домен получит случайный префикс.
- **Filament**: `--install-filament --filament-email EMAIL`, имя и пароль по желанию. Предупреди, что ставится `filament/filament:^5.0`, и совместимость с выбранной `--laravel-version` (по умолчанию 13.0, минимум 10.0) нужно проверить по документации Filament.
- **Нативная БД**: `--db-native`, а для MySQL ещё `--db-root-password`. Проверь предпосылки выше.
- **Basic Auth**: `--enable-basic-auth`, при желании с `--auth-user` и `--auth-password`.
- Необязательные параметры: явные учётные данные БД, порты, `--redis-password`, `--create-backup`, `--endpoint`.

Явные пароли составляй из символов `A-Za-z0-9@%_+-`. Значения попадают в `.env` без кавычек и в JSON без экранирования.

### 2. Проверь сервер
Выполни проверку предпосылок и узнай, есть ли уже `/var/www/<slug>` и volumes проекта (`docker volume ls --filter name=<slug>_`). Если есть, это **повторный запуск**: папка удалится без вопросов, а volume БД останется, и новые пароли к нему не применятся. В этом случае предложи сначала `remove.sh` или передать прежние учётные данные БД явно (README → «Повторный запуск»).

### 3. Собери команду и покажи её до запуска
```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```
Вместе с командой перечисли последствия:
- будут созданы контейнеры, сеть `<slug>` и volumes `<slug>_*`;
- изменится `/var/www/nginxproxy`, и он будет перезапущен, что на короткое время затронет все сайты сервера;
- будет запрошен сертификат Let's Encrypt (у Let's Encrypt есть лимиты на выпуск);
- если `/var/www/<slug>` уже существует, контейнеры будут остановлены, а папка **удалена** вместе с кодом;
- с `--db-native` БД и пользователь будут созданы в системной СУБД;
- с `--endpoint` все пароли уйдут на внешний URL.

**Запускай только после явного «да».** Одно подтверждение действует для одной команды.

### 4. Запусти
- Команда работает долго: собираются образы и выполняется composer. Запускай её в фоне или с большим таймаутом. Можно предложить пользователю выполнить её самому в своей SSH-сессии (`ssh -t`).
- В проверочном развёртывании без TTY `filament:install --panels` прошёл без вопросов. В интерактивном терминале установщик может что-то спросить; ID панели оставляй `admin`, иначе панель будет не на `/admin`.
- В выводе есть пароли. Не пересказывай и не цитируй их в чат без необходимости.
- Если миграции не прошли, скрипт только предупреждает. Если не удалась установка Filament, скрипт завершается: nginxproxy не перезапущен, SSL не получен (README → «Troubleshooting»).

### 5. Проверь результат
```bash
cd /var/www/<slug> && docker compose ps            # php, nginx, db, redis, cron, certbot_renew должны быть в статусе Up
docker compose ps -a                               # artisan/composer/npm/permissions в статусе Exited — это нормально
docker compose logs --tail=50 php nginx db
docker ps --filter name=nginxproxy && docker logs --tail=30 nginxproxy
docker compose run --rm artisan migrate:status
docker compose run --rm certbot certificates
curl -sS -o /dev/null -w '%{http_code}\n' https://<домен>/            # 200 (или 401 с Basic Auth)
curl -sS -o /dev/null -w '%{http_code}\n' https://<домен>/admin/login # с Filament: 200 (или 401)
```
По HTTP приложение не отдаётся: там обслуживается только ACME-challenge, редиректа на HTTPS нет. Поэтому ответ 404 по `http://` — это норма, а не ошибка.

### 6. Отчитайся
Сообщи slug, итоговый домен, URL сайта и панели, статус SSL и контейнеров, а также где лежат учётные данные. Пароли в отчёт не включай, если пользователь сам не попросил.

## Учётные данные
- `/var/www/<slug>/.env` хранит порты, пароли Redis, БД и Basic Auth, а также `FILAMENT_ADMIN_*` и `BACKUP_ARCHIVE_PATH`, если они были.
- `/var/www/<slug>/public_html/.env` — это `.env` Laravel с `DB_*` и `APP_URL`.
- Итоговый блок в выводе скрипта.
Читай эти файлы (`sudo cat ...`) только по просьбе пользователя и выдавай в чат лишь нужные значения. При `--db-native` + MySQL значение `DB_MYSQL_PASSWORD_ROOT` и строка `Root Password` в итогах — случайные, это **не** пароль root системного MySQL.

## Типичные проблемы

| Симптом | Причина и что делать |
|---|---|
| `Для получения SSL-сертификата необходимо указать --ssl-email` | Укажи `--ssl-email` или `--no-ssl`. |
| `Для установки Filament необходимо указать --filament-email` | Проверка выполняется при старте, до каких-либо изменений. Добавь флаг. |
| `Папка шаблона не найдена` | Скрипт лежит не рядом с `laravel/` и `nginxproxy/`. |
| `$'\r': command not found` | Файлы с CRLF. Выполни `sed -i 's/\r$//'` для скриптов и шаблонов. |
| Предупреждение «Не удалось выполнить миграции» | БД не успела подняться за 10 с, неверные `DB_*` или остался старый volume с другим паролем. Повтори `docker compose run --rm artisan migrate --force`. |
| «Не удалось получить SSL-сертификат» | DNS, порты 80/443 или nginxproxy. SSL-блоки остаются закомментированными. Получи сертификат и раскомментируй блоки вручную (README → «SSL не получен»). |
| nginxproxy в цикле перезапуска | Занят порт 80/443, `host not found in upstream` (в `sites/` лежит `*.conf` проекта, чьи контейнеры не работают) или внешняя сеть прерванного развёртывания. Смотри `docker logs nginxproxy`. |
| `composer` пишет, что пакет требует другую версию PHP | Composer работает в образе PHP 8.3 и проверяет требования к платформе. Выбери совместимые `--laravel-version`/Filament или поменяй Dockerfile (README → «Troubleshooting»). |
| 500 или `Permission denied` в `storage/` | Выполни `docker compose run --rm permissions`, особенно после `npm` (работает от root) и ручных правок от root. |
| 502 Bad Gateway | Контейнер php не запущен. Смотри `docker compose logs php`. |
| 413 или «файл слишком большой» | Лимиты: nginx проекта 900M, PHP по умолчанию 2M/8M, потому что `php.ini` не подключён (README → «Troubleshooting»). |
| Нативная БД: connection refused или timeout | СУБД не слушает `172.17.0.1`, `pg_hba.conf` или `bind-address` не пускает подсеть сети `<slug>`, либо мешает фаервол. |

## Жизненный цикл
Утилиты лежат в `/opt/laravel-deploy/` рядом с `deploy-laravel.sh` и требуют root (подробнее — README → «Управление проектом»). От типа проекта они не зависят и работают с любым проектом в `/var/www`, включая Moodle и HTML:
- `sudo bash /opt/laravel-deploy/list-projects.sh` — список проектов, их статус, SSL (по docker volume) и порты.
- `sudo bash /opt/laravel-deploy/deactivate.sh --slug <slug>` — выключает проект без удаления. Контейнеры останавливаются, `nginxproxy/sites/<slug>.conf` переименовывается в `.conf.disabled`, записи в compose прокси комментируются.
- `sudo bash /opt/laravel-deploy/activate.sh --slug <slug>` — возвращает конфиг, поднимает контейнеры и заново подключает прокси к сети проекта.
- `sudo bash /opt/laravel-deploy/remove.sh --slug <slug> --domain <домен>` — **необратимо** удаляет контейнеры, volumes (включая данные БД), сеть, конфиг прокси (в том числе `.disabled`), архив и папку. Для нативной MySQL добавь `--db-root-password`, иначе скрипт только напечатает SQL для ручного удаления. Скрипт интерактивно просит ввести `yes`: запускай его через `ssh -t` или отдай пользователю. Не обходи этот запрос (`echo yes |`) без явной просьбы. Перед запуском получи отдельное подтверждение, а root-пароль пусть введёт сам пользователь.
- Повторный `deploy-laravel.sh` с тем же slug означает переустановку кода с нуля (README → «Повторный запуск»).
