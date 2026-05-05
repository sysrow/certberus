# Certberus

Unified automation for **SSL/TLS certificate deployment** on Apache, nginx and Tomcat.
Supports Let's Encrypt, HARICA / CESNET TCS and ZeroSSL. Pure bash + standard
Linux tooling — no Python / Go / Node.js, no daemon.

---

## Two ways to use it

### 1. Interactive (first time / one-off)

```bash
sudo certberus interactive
```

Wizard. Detects the webserver, asks for CA, email, EAB credentials (HARICA/ZeroSSL),
auto-discovers domains from the webserver config, runs preflight, issues the cert.

### 2. Automatic (production / cron / CI)

```bash
sudo certberus auto
```

Reads `/etc/certberus/config.env`, validates required fields fail-fast, never asks
a question, writes everything to `/var/log/certberus/certberus.log`.

| | `interactive` | `auto` |
|---|---|---|
| Asks questions | yes | never |
| Reads config.env | yes (defaults) | yes (source of truth) |
| Auto-detects domains | yes | yes (if `CB_DOMAINS` empty) |
| Fail-fast on missing email/EAB | no (asks) | yes |
| Suitable for cron | no | **yes** |

That's it. Everything else is operational tooling (`status`, `doctor`, `expiry`, …).

---

## Examples

The two main commands work out of the box on a freshly installed webserver — bundle or .deb,
both bootstrap `/etc/certberus/` on first run.

### Apache + Let's Encrypt, single domain

```bash
# Bundle (one-shot, no install):
curl -fsSLo /usr/local/sbin/certberus \
  https://github.com/Tristram1337/certberus/releases/latest/download/certberus-0.1.3.bundle
chmod +x /usr/local/sbin/certberus

sudo certberus auto --email admin@example.com --domain www.example.com
# Cert appears in /var/lib/apache2/md/md/store/domains/www.example.com/ (10-60s, async).
sudo certberus cert-info www.example.com
```

The first `auto` run also writes `/etc/certberus/config.env` for you, so cron can call
`certberus auto` with no flags afterwards.

### Test in staging first (no rate limits, untrusted certs)

```bash
sudo certberus auto --staging --email admin@example.com --domain www.example.com
sudo certberus cert-info www.example.com   # issuer = "STAGING - ..."
sudo certberus auto --email admin@example.com --domain www.example.com   # production
```

### Multiple domains (SAN cert)

```bash
sudo certberus auto --email admin@example.com \
  --domain www.example.com --domain api.example.com --domain example.com
```

### Auto-discover domains from existing webserver config

```bash
sudo certberus auto --email admin@example.com
# Reads ServerName/server_name/Host name from Apache, nginx and Tomcat
# and includes only domains whose DNS A/AAAA points at this server.
sudo certberus discover     # preview without issuing
```

### nginx + Let's Encrypt

```bash
sudo certberus auto --webserver nginx --email admin@example.com --domain www.example.com
```

### Tomcat 9+ with certbot (port 80 needs a strategy)

```bash
# webroot via existing reverse proxy (nginx/Apache in front):
sudo certberus auto --webserver tomcat --port80 webroot --webroot /var/www/html \
  --email admin@example.com --domain api.example.com

# or temporarily open port 80 directly to Tomcat:
sudo certberus auto --webserver tomcat --port80 iptables \
  --email admin@example.com --domain api.example.com
```

### HARICA / CESNET TCS (EAB)

```bash
sudo certberus auto \
  --ca harica \
  --email admin@example.com \
  --eab-kid YOUR_KID \
  --eab-hmac YOUR_HMAC_BASE64 \
  --acme-url 'https://acme.harica.gr/<ALIAS>/directory' \
  --domain www.example.com
```

(Or fill the same `CB_EAB_KID`, `CB_EAB_HMAC`, `CB_ACME_URL` in `/etc/certberus/config.env`
and just run `sudo certberus auto`.)

### ZeroSSL

```bash
sudo certberus auto --ca zerossl --email admin@example.com \
  --eab-kid YOUR_KID --eab-hmac YOUR_HMAC --domain www.example.com
```

### Cron renewal (after first successful auto)

```bash
echo '0 3 * * * root /usr/local/sbin/certberus auto >>/var/log/certberus/cron.log 2>&1' \
  | sudo tee /etc/cron.d/certberus
```

For Apache mod_md no cron is needed — Apache itself handles renewal asynchronously.
The cron above is a belt-and-suspenders idempotent re-run.

### Diagnostics

```bash
sudo certberus doctor                        # OS / firewall / ports / modules / versions
sudo certberus test-domain www.example.com   # DNS + CAA + port 80 + cert per single domain
sudo certberus discover                      # what domains point here
sudo certberus cert-info                     # all known certs (mod_md, certbot, live HTTPS)
sudo certberus expiry                        # expiry table
sudo certberus status                        # high-level overview
```

### Dry-run (simulate, no changes)

```bash
sudo certberus auto --dry-run --email admin@example.com --domain www.example.com
```

### Rollback after a bad change

```bash
sudo certberus rollback   # restores the last snapshot of /etc/apache2 (or /etc/nginx, /etc/tomcat*)
```

### Behind NAT / load balancer / floating IP

```bash
# Local interface IP differs from public DNS A record:
sudo certberus auto --email admin@example.com --domain www.example.com --skip-dns-check
```

---

## Install

You have two options.

### A) System install (recommended for servers)

```bash
git clone https://github.com/Tristram1337/certberus.git
cd certberus
sudo ./install.sh
```

Installs `/usr/local/sbin/certberus` (on PATH), libraries in `/usr/local/lib/certberus/`,
config in `/etc/certberus/`, logs in `/var/log/certberus/`, snapshots in
`/var/backups/certberus/`. Logrotate is configured automatically.

Uninstall: `sudo ./install.sh --uninstall` (config and logs are preserved).

### B) Single-file binary (drop-in, no install)

Pre-built binary is attached to every GitHub Release:

```bash
# Latest release
curl -fsSLo certberus \
  https://github.com/Tristram1337/certberus/releases/latest/download/certberus-0.1.0.bundle
chmod +x certberus
sudo install -m 0755 certberus /usr/local/sbin/certberus

sudo certberus interactive
```

Or build it yourself from source:

```bash
git clone https://github.com/Tristram1337/certberus.git
cd certberus
./build/bundle.sh           # produces dist/certberus (~180 KB, single bash file)

sudo ./dist/certberus interactive
# or copy it anywhere on your PATH:
sudo install -m 0755 dist/certberus /usr/local/sbin/certberus
```

`dist/certberus` is a self-contained bash script with all libraries and webserver
modules embedded. At startup it unpacks them into a private `mktemp` directory and
cleans up on exit. The CLI is identical to the system install — same commands, same
config file (`/etc/certberus/config.env`), same hooks (`/etc/certberus/hooks/...`).

Use case: throwaway VMs, image baking, CI runners, situations where you do not want
to leave files in `/usr/local/lib`.

---

## Configure

Edit `/etc/certberus/config.env` (5 mandatory values):

```bash
CB_EMAIL="admin@example.com"        # contact for the CA
CB_CA="letsencrypt"                 # letsencrypt | harica | zerossl
CB_WEBSERVER="auto"                 # auto | apache | nginx | tomcat
CB_DOMAINS=""                       # empty = autodetect from VirtualHost / server_name
CB_STAGING=0                        # 1 = test CA (no rate limits, untrusted certs)

# Only for HARICA / ZeroSSL:
CB_EAB_KID=""
CB_EAB_HMAC=""
CB_ACME_URL=""                      # HARICA: https://acme.harica.gr/<ALIAS>/directory
```

Advanced tuning lives in `/etc/certberus/advanced.env` — every value is commented
out, defaults are sensible, you only uncomment what you want to change.

The same values can be passed on the CLI via `--email`, `--ca`, `--domain`,
`--eab-kid`, `--eab-hmac`, `--acme-url`, or `--set CB_NAME=value` for advanced overrides.

---

## What it does

| | Apache (mod_md) | nginx (certbot) | Tomcat 9+ (certbot) |
|---|:-:|:-:|:-:|
| Let's Encrypt | yes | yes | yes |
| HARICA / CESNET TCS (EAB) | yes | yes | yes |
| ZeroSSL (EAB) | yes | yes | yes |
| Staging (test CA) | yes | yes | yes |
| Auto-detect domains | VirtualHost | server_name | Host name |
| Snapshot before change | yes | yes | yes |
| Rollback on error | yes | yes | atomic cert swap |
| Firewall auto-open (80/443) | yes | yes | yes |
| Auto-renewal | mod_md built-in | certbot.timer | certbot.timer |
| Custom pre/post hooks | yes | yes | yes |

---

## Recommended first run on Apache

```bash
sudo ./install.sh
sudo $EDITOR /etc/certberus/config.env       # at minimum CB_EMAIL

sudo certberus doctor                        # verify environment
sudo certberus auto --staging                # safe test (untrusted certs, no rate limits)
sudo certberus auto                          # production
sudo certberus status
```

For non-trivial setups (HARICA EAB, multiple webservers, custom webroot) start with
`sudo certberus interactive` — the wizard collects everything and you can later
just re-run with `auto`.

---

## Operational commands

```bash
certberus status        # which certs, when they expire
certberus expiry        # expiration table for all managed certs
certberus doctor        # DNS / firewall / port / module / version checks
certberus discover      # which domains point at this server
certberus test-domain D # full preflight (DNS + CAA + port 80 + cert) for one domain
certberus renew         # alias for `auto` (idempotent)
certberus revoke D      # revoke a cert
certberus rollback      # restore the last snapshot
certberus hooks list    # list installed hooks
```

Every command accepts `-n / --dry-run` (simulate, no changes) and `-v / --verbose`.

---

## Hooks (run-parts pattern)

Drop scripts into `/etc/certberus/hooks/<event>.d/*.sh`:

| Event | When |
|---|---|
| `pre-issue`, `post-issue` | Around the ACME request |
| `pre-deploy`, `post-deploy` | Around cert deployment |
| `pre-reload`, `post-reload` | Around webserver reload |
| `on-failure`, `on-rollback` | On error / after rollback |
| `renewing`, `renewed`, `installed`, `expiring`, `errored` | mod_md events (proxied from `MDMessageCMD`) |
| `ocsp-renewed`, `ocsp-errored`, `challenge-setup` | further mod_md events |

Each hook receives these env vars: `CA_EVENT`, `CA_WEBSERVER`, `CA_PRIMARY_DOMAIN`,
`CA_DOMAIN_LIST`, `CA_CERT_PATH`, `CA_KEY_PATH`, `CA_CERT_ISSUER`, `CA_STAGING`,
`CA_LOG_FILE`, `CA_SNAPSHOT_PATH`, `CA_SOURCE`.

Examples in `/etc/certberus/hooks/examples/` (slack-notify, mail-admin, verify-https,
iptables ACME allow/revoke, …). See `/etc/certberus/hooks/README.md`.

---

## Firewall

Auto-detects and can open 80/443 on **firewalld**, **ufw**, **nftables**, or **iptables**
(both legacy and nf_tables backends).

For Tomcat there is an optional 80→8080 redirect (so Tomcat does not need to bind a
privileged port).

For `CB_CA=harica` Certberus does **not** open the firewall by default — HARICA
typically runs over a pre-validated domain set. If your particular HARICA account
returns HTTP-01 timeouts, open 80/443 manually or set
`CB_HARICA_FIREWALL_AUTO_OPEN=1` (or pass `--open-firewall`).

For NAT / load-balancer / floating-IP setups where the public IP differs from the
local interface, use `--skip-dns-check` to bypass the local DNS-points-here check.

---

## Supported OS

| OS | Apache | nginx | Tomcat |
|---|:-:|:-:|:-:|
| Debian 10 | yes | yes | yes |
| Debian 11 / 12 | yes | yes | yes |
| Ubuntu 18.04 | upgrade Apache to 2.4.34+ | yes | yes |
| Ubuntu 20.04 / 22.04 / 24.04 | yes | yes | yes |
| Rocky / AlmaLinux 8+ | should work, untested | | |

---

## Troubleshooting

```bash
sudo tail -f /var/log/certberus/certberus.log
sudo journalctl -t certberus -f
sudo certberus doctor
sudo certberus rollback
```

Bash syntax check across the codebase:

```bash
for f in bin/certberus lib/*.sh webservers/*.sh; do bash -n "$f" && echo "OK: $f"; done
```

---

## License

MIT — see [LICENSE](LICENSE).
