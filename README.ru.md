[🇬🇧 English](README.md) &nbsp;|&nbsp; 🇷🇺 **Русский**

# Web Server Script

Универсальный установщик и менеджер LAMP / LEMP стека для Debian / Ubuntu.

**Выбор при установке:**
- Web-сервер: **Apache** (mpm_event + PHP-FPM через mod_proxy_fcgi) **или Nginx** (PHP-FPM через fastcgi_pass)
- БД: **MariaDB** **или PostgreSQL**
- Web-UI для БД:
  - MariaDB → выбор **phpMyAdmin** *или* **Adminer**
  - PostgreSQL → **Adminer** (принудительно — phpPgAdmin поддерживает только PG ≤ 13 и заброшен)

В каждом стеке: PHP-FPM 8.4 (8.5 на Ubuntu 26.04 нативно), HTTP/2, реальные IP от Cloudflare, Composer, fail2ban.

---

## Быстрый старт (интерактивное меню)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

или через `wget`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

Меню:

```
=================================================================
  Web Server Manager  v4.0
=================================================================
  System    : Debian GNU/Linux 13 (trixie)
  Web server: <none>  (not installed)
  Database  : <none>
  PHP-FPM   : <none>
  Sites     : 0
-----------------------------------------------------------------
  1) Install web server         (выбор Apache/Nginx + MariaDB/PostgreSQL)
  2) Add new site               (vhost + изолированный FPM pool + опц. БД)
  3) Remove a site              (vhost + pool + опц. user/files/cert/DB)
  4) Uninstall everything       (деструктивно — снос пакетов + данных)
  0) Exit
-----------------------------------------------------------------
Select an action [0-4]:
```

При выборе **1) Install** на чистом сервере меню спросит web-сервер, БД и
(для MariaDB) UI для админки, и запустит соответствующий установщик. Выбор сохранится в
`/etc/web_server_script.conf`. Все последующие действия (Add/Remove site,
Uninstall) автоматически идут к нужному скрипту — стек больше не спрашивают.

**Протестировано на:** Debian 12/13 и Ubuntu 22.04/24.04/26.04, все 4 комбинации
стеков (Apache+MariaDB, Apache+PostgreSQL, Nginx+MariaDB, Nginx+PostgreSQL).

---

## Прямой запуск (минуя меню)

Репозиторий разбит на каталоги `apache/` и `nginx/`. У каждого свой набор из
4 действий — выбираешь тот, что соответствует нужному (или уже установленному)
стеку.

### Стек Apache

```bash
# Установка — интерактивно (спросит выбор БД)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/install.sh)

# Добавить сайт
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/add-site.sh)

# Удалить сайт
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/remove-site.sh)

# Снести всё
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/uninstall.sh)
```

### Стек Nginx

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/install.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/add-site.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/remove-site.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/uninstall.sh)
```

### Без интерактива (CI / Ansible / cloud-init)

Все скрипты понимают переопределение через env-переменные — интерактивные
вопросы задаются только для незаданных значений. Примеры:

```bash
# Apache + MariaDB + phpMyAdmin (по умолчанию)
curl -fsSL .../apache/install.sh | \
  DATABASE=mariadb \
  DB_UI=phpmyadmin \
  MYSQL_ROOT='SecureRoot123!' \
  PHPMYADMIN_DIR='myadmin42' \
  bash

# Apache + MariaDB + Adminer
curl -fsSL .../apache/install.sh | \
  DATABASE=mariadb \
  DB_UI=adminer \
  MYSQL_ROOT='SecureRoot123!' \
  ADMINER_DIR='admdb' \
  bash

# Nginx + PostgreSQL (Adminer принудительно)
curl -fsSL .../nginx/install.sh | \
  DATABASE=pgsql \
  PG_PASS='SecurePg123!' \
  ADMINER_DIR='admdb' \
  bash

# Добавить сайт с автогенерацией пароля БД
curl -fsSL .../apache/add-site.sh | \
  DOMAIN=example.com \
  NEWUSER=example \
  SITE_PASS='SitePass123!' \
  SSL_SETUP=y \
  CERTBOT_EMAIL=admin@example.com \
  CREATE_DB=yes \
  DB_NAME=example_db \
  DB_USER=example_user \
  bash
# DB_PASS сгенерируется (24 символа) и сохранится в /www/example.com/db.txt

# Удалить сайт + удалить БД + удалить системного юзера
curl -fsSL .../nginx/remove-site.sh | \
  DOMAIN=example.com \
  DELETE_USER=yes DELETE_FILES=yes DELETE_CERT=yes DELETE_DB=yes \
  FORCE=yes bash

# Снести всё
curl -fsSL .../apache/uninstall.sh | FORCE=yes DELETE_CERTS=yes bash
```

Для Ubuntu 26.04 (где `ondrej/php` PPA пока без `resolute`):
```bash
curl -fsSL .../apache/install.sh | \
  PHP_VER=8.5 DATABASE=mariadb MYSQL_ROOT='...' PHPMYADMIN_DIR='...' bash
```

---

## Что устанавливается

**Оба стека (Apache и Nginx) ставят:**

- PHP-FPM с модулями: mysql, **pgsql** (оба драйвера БД ставятся всегда — для гибкости сайтов), cli, ldap, xml, curl, mbstring, zip, bcmath, gd, soap, bz2, intl, gmp, redis, imagick (опционально)
- Composer (последняя стабильная версия)
- fail2ban для защиты SSH от брут-форса
- Утилиты: mc, screen
- Реальные IP Cloudflare автоматически подтягиваются и настраиваются (`mod_remoteip` для Apache, `set_real_ip_from` для Nginx)
- HTTP/2

**Стек MariaDB добавляет:** `mariadb-server` плюс на выбор:
- **phpMyAdmin** (последний с phpmyadmin.net, ~12 МБ) на отдельном PHP-FPM pool, доступ по `/<алиас>`
- или **Adminer** (один PHP-файл ~500 КБ, последний с adminer.org, поддерживает MySQL/PG/SQLite/MSSQL/Oracle) на своём pool

**Стек PostgreSQL добавляет:** `postgresql` + `postgresql-contrib` плюс **Adminer** (принудительно — phpPgAdmin поддерживает только PG ≤ 13 и заброшен). `pg_hba.conf` настраивается на scram-sha-256 пароль-аутентификацию для localhost, чтобы Adminer мог логиниться по TCP.

**`add-site.sh`** для каждого домена создаёт:

- Vhost / server-block с редиректом HTTP→HTTPS, HTTP/2, security-заголовками (HSTS, X-Frame-Options и т.п.)
- Изолированный PHP-FPM pool с `open_basedir` jail в `/www/$DOMAIN`
- Системного юзера, владеющего файлами сайта (отдельно от www-data — сайт не может выйти за свою песочницу)
- Cron-задачу для очистки PHP-сессий
- `logrotate` конфиг
- Опционально SSL Let's Encrypt через Certbot (auto-redirect на HTTPS, только TLSv1.2/1.3)
- **Опционально БД под этот сайт** — при `CREATE_DB=yes`:
  - Спросит (или примет через env) `DB_NAME`, `DB_USER`
  - Сгенерирует пароль 24 символа если `DB_PASS` не передан
  - Создаст БД + юзера с полными правами только на эту БД
  - Сохранит креды в `/www/$DOMAIN/db.txt` (mode 600, owner = юзер сайта)
  - Один раз выведет пароль в stdout в самом конце

---

## Структура файлов

```
/etc/web_server_script.conf                  ← инфо о стеке (WEB_SERVER, DATABASE, PHP_VER, ...)
/etc/apache2/sites-available/<domain>.conf   ← Apache vhost
   ИЛИ
/etc/nginx/sites-available/<domain>          ← Nginx server block
/etc/php/<ver>/fpm/pool.d/<domain>.conf      ← FPM pool под этот сайт
/etc/cron.d/php-sessions-<domain>            ← очистка сессий
/etc/logrotate.d/<domain>.conf               ← ротация логов
/run/php/php<ver>-fpm-<domain>.sock          ← FPM-сокет (на сайт)
/www/<domain>/www                            ← document root (owner: юзер сайта, группа: www-data, 750)
/www/<domain>/logs                           ← логи веб-сервера и PHP
/www/<domain>/tmp                            ← загрузки + сессии
/www/<domain>/db.txt                         ← (если CREATE_DB) mode 600
```

После заливки кода приложения:

```bash
chown -R <user>:www-data /www/<domain>/www
chmod -R 750 /www/<domain>/www
```

---

## Форк / своя версия

Меню скачивает каждый экшен с GitHub. Чтобы запустить со своего форка/ветки:

```bash
REPO_URL=https://raw.githubusercontent.com/myname/web_server_script/dev \
  bash <(curl -fsSL "$REPO_URL/web-server.sh")
```

Каждый под-скрипт самодостаточен — без shared library, без внешних
зависимостей кроме `apt`, `curl`, `wget`, `unzip`, `tar`.

---

## Заметки

- Запускать от `root` (или через `sudo`).
- Лог установки: `install.log` (в текущей директории).
- Скрипт намеренно НЕ запускает `apt-get upgrade -y` — он подтянул бы сотни МБ
  левых пакетов (ядро, firmware) и сильно растянул установку. Запусти
  `apt-get upgrade` руками после, если нужен полный security-апдейт.
- Один web-сервер + одна БД на хост. Чтобы сменить стек — `uninstall.sh` →
  `install.sh` с новым выбором.
- Оба драйвера БД (`php-mysql` и `php-pgsql`) ставятся всегда независимо от
  выбора БД — это делает отдельные сайты переносимыми, если потом захочешь
  подключить какой-то к другой БД.
