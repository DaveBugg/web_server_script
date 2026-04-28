# Web Server Script

Universal LAMP web-server installer and site manager for Debian / Ubuntu.

**Stack:** Apache 2.4 (MPM Event) + PHP-FPM 8.4 + MariaDB + phpMyAdmin + HTTP/2 + `mod_remoteip` (Cloudflare real-IP)

**Tested on:**

| OS | Codename | PHP source | PHP version |
|---|---|---|---|
| Debian 12 | bookworm | sury.org | 8.4.20 |
| Debian 13 | trixie | native | 8.4.16 |
| Ubuntu 22.04 | jammy | ondrej PPA | 8.4.20 |
| Ubuntu 24.04 | noble | ondrej PPA | 8.4.20 |
| Ubuntu 26.04 | resolute | native (`PHP_VER=8.5`) | 8.5.4 |

---

## Quick start (interactive menu)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

or with `wget`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
```

You'll see a menu:

```
=================================================================
  Web Server Manager
=================================================================
  System    : Ubuntu 24.04.5 LTS
  Web server: not installed
  PHP-FPM   : not detected
  Sites     : 0
-----------------------------------------------------------------
  1) Install web server         (Apache + PHP-FPM + MariaDB + phpMyAdmin)
  2) Add new site               (vhost + isolated PHP-FPM pool + SSL)
  3) Remove a site              (vhost + pool + optional user/files/cert)
  4) Uninstall everything       (destructive — purges all packages + data)
  0) Exit
-----------------------------------------------------------------
Select an action [0-4]:
```

---

## Direct invocation (skip the menu)

Each action is also a standalone script — call it directly:

### 1. Install web server

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/install.sh)
```

Non-interactive (CI / Ansible / cloud-init):

```bash
curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/install.sh | \
  MYSQL_ROOT='SecureRoot123!' \
  PHPMYADMIN_DIR='myadmin42' \
  bash
```

For Ubuntu 26.04 (until ondrej PPA adds `resolute`):

```bash
curl -fsSL .../install.sh | PHP_VER=8.5 MYSQL_ROOT='...' PHPMYADMIN_DIR='...' bash
```

### 2. Add new site

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/add-site.sh)
```

Non-interactive:

```bash
curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/add-site.sh | \
  DOMAIN=example.com \
  NEWUSER=example \
  SITE_PASS='SitePass123!' \
  SSL_SETUP=y \
  CERTBOT_EMAIL=admin@example.com \
  bash
```

### 3. Remove a site

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/remove-site.sh)
```

The script lists all configured sites and lets you pick one (or pass `DOMAIN=`):

```bash
curl -fsSL .../remove-site.sh | \
  DOMAIN=example.com \
  DELETE_USER=yes \
  DELETE_FILES=yes \
  DELETE_CERT=yes \
  FORCE=yes \
  bash
```

### 4. Uninstall everything (destructive)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/uninstall.sh)
```

Requires typing `YES, DELETE EVERYTHING` to confirm. Skip the prompt with `FORCE=yes`:

```bash
curl -fsSL .../uninstall.sh | FORCE=yes DELETE_CERTS=yes bash
```

---

## What gets installed

**`install.sh`:**

- Apache 2.4 with MPM Event, `mod_proxy_fcgi`, `mod_http2`, `mod_remoteip`, `mod_ssl`, `mod_headers`
- PHP-FPM 8.4 (or 8.5 via `PHP_VER`) with: mysql, cli, ldap, xml, curl, mbstring, zip, bcmath, gd, soap, bz2, intl, gmp, redis, imagick (optional)
- MariaDB server with secure root password
- phpMyAdmin (latest stable, downloaded from phpmyadmin.net) on a dedicated PHP-FPM pool, served at `/<your-alias>`
- Cloudflare IP ranges automatically configured via `mod_remoteip` (so logs show real visitor IPs)
- HTTP/2 enabled
- Composer (latest stable, installed to `/usr/local/bin/composer`)
- `fail2ban` for SSH brute-force protection
- `mc`, `screen` utilities

**`add-site.sh`** for each domain creates:

- Apache vhost with HTTP→HTTPS redirect, HTTP/2, security headers (HSTS, X-Frame-Options, etc.)
- A dedicated PHP-FPM pool with `open_basedir` jail to `/www/$DOMAIN`
- A system user owning the site files (separate from www-data — site can't escape its sandbox)
- Cron job for PHP session cleanup
- `logrotate` config
- Optional Let's Encrypt SSL via Certbot (auto-redirect to HTTPS, TLSv1.2/1.3 only)
- Bare-IP catch-all vhost that returns 403 (so the server only responds to known hostnames)

---

## Filesystem layout

```
/etc/apache2/sites-available/<domain>.conf   ← vhost
/etc/php/<ver>/fpm/pool.d/<domain>.conf      ← per-site FPM pool
/etc/cron.d/php-sessions-<domain>            ← session cleanup
/etc/logrotate.d/<domain>.conf               ← log rotation
/run/php/php<ver>-fpm-<domain>.sock          ← FPM socket
/www/<domain>/www                            ← document root (owner: site user, group: www-data, 750)
/www/<domain>/logs                           ← Apache + PHP error logs
/www/<domain>/tmp                            ← uploads + sessions
```

After deploying app code:

```bash
chown -R <user>:www-data /www/<domain>/www
chmod -R 750 /www/<domain>/www
```

---

## Forking / customising

The menu script (`web-server.sh`) downloads each action from GitHub. To use your own fork or branch, set `REPO_URL`:

```bash
REPO_URL=https://raw.githubusercontent.com/myname/web_server_script/dev \
  bash <(curl -fsSL "$REPO_URL/web-server.sh")
```

Each sub-script is fully self-contained — no shared library, no external dependencies beyond `apt`, `curl`, `wget`.

---

## Notes

- Run as `root` (or via `sudo`).
- Install log: `install.log` (in the working directory).
- The script intentionally does NOT run `apt-get upgrade -y` — it would pull hundreds of MB of unrelated packages (kernel, firmware) and dramatically slow the install. Run `apt-get upgrade` manually afterwards if you want a full security refresh.
- `apt-get install` already pulls the latest version of every package the script needs from the enabled repos.
- The install script is idempotent for repos but NOT for site/user creation — re-running it will re-prompt for MySQL root password, which will fail because root already has a password. Use `add-site.sh` for additional sites; use `uninstall.sh` + `install.sh` for a complete reset.
