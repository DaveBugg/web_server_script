# Web Server Script

Universal LAMP / LEMP web-server installer and site manager for Debian / Ubuntu.

**Pick at install time:**
- Web server: **Apache** (mpm_event + PHP-FPM via mod_proxy_fcgi) **or Nginx** (PHP-FPM via fastcgi_pass)
- Database: **MariaDB** (with phpMyAdmin) **or PostgreSQL** (with phpPgAdmin)

PHP-FPM 8.4 (8.5 on Ubuntu 26.04 native), HTTP/2, Cloudflare real-IP, Composer, fail2ban included on every stack.

---

## Quick start (interactive menu)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

or with `wget`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

Menu:

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
  1) Install web server         (pick Apache/Nginx + MariaDB/PostgreSQL)
  2) Add new site               (vhost + isolated FPM pool + optional DB)
  3) Remove a site              (vhost + pool + optional user/files/cert/DB)
  4) Uninstall everything       (destructive — purges packages + data)
  0) Exit
-----------------------------------------------------------------
Select an action [0-4]:
```

When you pick **1) Install** on a fresh server, the menu asks two questions
(web server, database) and then runs the matching installer. The choice is
persisted in `/etc/web_server_script.conf`. Subsequent actions (Add/Remove
site, Uninstall) automatically route to the correct sub-script — you don't
get asked the stack question again.

**Tested on:** Debian 12/13 and Ubuntu 22.04/24.04/26.04 with all 4 stack combos
(Apache+MariaDB, Apache+PostgreSQL, Nginx+MariaDB, Nginx+PostgreSQL).

---

## Direct invocation (skip the menu)

The repo is split into `apache/` and `nginx/` directories. Each has its own
4 actions. Choose the one matching the stack you want / have.

### Apache stack

```bash
# Install — interactive (asks DB choice)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/install.sh)

# Add a site
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/add-site.sh)

# Remove a site
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/remove-site.sh)

# Uninstall everything
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/uninstall.sh)
```

### Nginx stack

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/install.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/add-site.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/remove-site.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/uninstall.sh)
```

### Non-interactive (CI / Ansible / cloud-init)

Every script honours env-var overrides — interactive prompts only fire for
unset variables. Examples:

```bash
# Install Apache + MariaDB without prompts
curl -fsSL .../apache/install.sh | \
  DATABASE=mariadb \
  MYSQL_ROOT='SecureRoot123!' \
  PHPMYADMIN_DIR='myadmin42' \
  bash

# Install Nginx + PostgreSQL
curl -fsSL .../nginx/install.sh | \
  DATABASE=pgsql \
  PG_PASS='SecurePg123!' \
  PHPPGADMIN_DIR='mypga' \
  bash

# Add site with auto-generated DB
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
# DB_PASS is auto-generated (24 chars) and saved to /www/example.com/db.txt

# Remove site + drop DB + drop user
curl -fsSL .../nginx/remove-site.sh | \
  DOMAIN=example.com \
  DELETE_USER=yes DELETE_FILES=yes DELETE_CERT=yes DELETE_DB=yes \
  FORCE=yes bash

# Uninstall
curl -fsSL .../apache/uninstall.sh | FORCE=yes DELETE_CERTS=yes bash
```

For Ubuntu 26.04 (where `ondrej/php` PPA may not yet have `resolute`):
```bash
curl -fsSL .../apache/install.sh | \
  PHP_VER=8.5 DATABASE=mariadb MYSQL_ROOT='...' PHPMYADMIN_DIR='...' bash
```

---

## What gets installed

**Both stacks (Apache and Nginx) install:**

- PHP-FPM with: mysql, **pgsql** (both DB drivers regardless of choice — for site flexibility), cli, ldap, xml, curl, mbstring, zip, bcmath, gd, soap, bz2, intl, gmp, redis, imagick (optional)
- Composer (latest stable)
- fail2ban for SSH brute-force protection
- mc, screen utilities
- Cloudflare IP ranges auto-fetched and configured (`mod_remoteip` for Apache, `set_real_ip_from` for Nginx)
- HTTP/2

**MariaDB stack adds:** mariadb-server + phpMyAdmin (latest from phpmyadmin.net) on a dedicated PHP-FPM pool, served at `/<your-alias>`

**PostgreSQL stack adds:** postgresql + postgresql-contrib + phpPgAdmin 7.13 (from upstream tarball) on a dedicated PHP-FPM pool, served at `/<your-alias>`. `pg_hba.conf` is configured for scram-sha-256 password auth on localhost so phpPgAdmin can log in.

**`add-site.sh`** for each domain creates:

- Web server vhost / server block with HTTP→HTTPS redirect, HTTP/2, security headers (HSTS, X-Frame-Options, etc.)
- Dedicated PHP-FPM pool with `open_basedir` jail to `/www/$DOMAIN`
- A system user owning the site files (separate from www-data — site can't escape its sandbox)
- Cron job for PHP session cleanup
- `logrotate` config
- Optional Let's Encrypt SSL via Certbot (auto-redirect to HTTPS, TLSv1.2/1.3 only)
- **Optional per-site database** — when `CREATE_DB=yes`:
  - Asks (or accepts via env) `DB_NAME`, `DB_USER`
  - Generates a 24-char password if `DB_PASS` not provided
  - Creates DB + user with full privileges on that DB only
  - Saves credentials to `/www/$DOMAIN/db.txt` (mode 600, owner = site user)
  - Echoes the password to stdout once at the end

---

## Filesystem layout

```
/etc/web_server_script.conf                  ← stack info (WEB_SERVER, DATABASE, PHP_VER, ...)
/etc/apache2/sites-available/<domain>.conf   ← Apache vhost
   OR
/etc/nginx/sites-available/<domain>          ← Nginx server block
/etc/php/<ver>/fpm/pool.d/<domain>.conf      ← per-site FPM pool
/etc/cron.d/php-sessions-<domain>            ← session cleanup
/etc/logrotate.d/<domain>.conf               ← log rotation
/run/php/php<ver>-fpm-<domain>.sock          ← FPM socket (per site)
/www/<domain>/www                            ← document root (owner: site user, group: www-data, 750)
/www/<domain>/logs                           ← Web server + PHP error logs
/www/<domain>/tmp                            ← uploads + sessions
/www/<domain>/db.txt                         ← (if CREATE_DB) mode 600
```

After deploying app code:

```bash
chown -R <user>:www-data /www/<domain>/www
chmod -R 750 /www/<domain>/www
```

---

## Forking / customising

The menu downloads each action from GitHub. To use your own fork or branch:

```bash
REPO_URL=https://raw.githubusercontent.com/myname/web_server_script/dev \
  bash <(curl -fsSL "$REPO_URL/web-server.sh")
```

Each sub-script is fully self-contained — no shared library, no external
dependencies beyond `apt`, `curl`, `wget`, `unzip`, `tar`.

---

## Notes

- Run as `root` (or via `sudo`).
- Install log: `install.log` (in the working directory).
- The script intentionally does NOT run `apt-get upgrade -y` — it would pull
  hundreds of MB of unrelated packages (kernel, firmware) and dramatically
  slow the install. Run `apt-get upgrade` manually afterwards if you want a
  full security refresh.
- One web server + one database per host. To switch stacks, run `uninstall.sh`
  then `install.sh` again with the new choice.
- Both PHP DB drivers (`php-mysql` and `php-pgsql`) are installed regardless
  of which DB you pick — this makes individual sites portable if you later
  need to point one at a different DB.
