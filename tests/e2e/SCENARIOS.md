# Certberus end-to-end chaos scenarios

This matrix drives `tests/e2e/run-matrix.sh`. Every row is an independent
test on a remote Debian box. Definition of done for each scenario:

> After `certberus install`, `openssl s_client -servername <fqdn> -connect <fqdn>:443 </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates` returns a certificate whose **issuer** matches the chosen CA (`(STAGING) Let's Encrypt` for staging, `Let's Encrypt` for prod) and whose **CN/SAN** covers the requested domain. Exit code 0 from certberus is necessary but not sufficient.

## Targets

| Alias  | OS                       | IP (env)                | Wildcard DNS (env)                |
|--------|--------------------------|-------------------------|-----------------------------------|
| deb12  | Debian 12 (bookworm)     | `$CB_E2E_DEB12_IP`      | `*.$CB_E2E_DEB12_WILDCARD`        |
| deb13  | Debian 13 (trixie)       | `$CB_E2E_DEB13_IP`      | `*.$CB_E2E_DEB13_WILDCARD`        |

All operator-specific values (IPs, wildcard zones, contact e-mail) come from
environment variables — none are baked into the repo. Before running the
matrix, export them so `tests/e2e/lib/box.sh` can build the registry:

```
export CB_E2E_DEB12_IP=...
export CB_E2E_DEB12_WILDCARD=example12.test
export CB_E2E_DEB13_IP=...
export CB_E2E_DEB13_WILDCARD=example13.test
export CB_E2E_EMAIL=acme-staging@example.test
```

Each wildcard must be a DNS apex below which `*.WILDCARD` resolves to the
respective box IP. The wildcard A record is the operator's responsibility —
the matrix never mutates the zone. Scenarios then claim their own unique
subdomain (`s<NNN>.<WILDCARD>`) so LE cache/account state does not bleed
between tests.

## ACME

- Staging: `https://acme-staging-v02.api.letsencrypt.org/directory` for all
  scenarios except the two final prod smokes (P-01, P-02).
- Contact e-mail: `$CB_E2E_EMAIL`.

## Reset before each scenario

```
apt-get -y purge apache2 'libapache2-mod-md*' certbot nginx tomcat9 tomcat10 jetty9 jetty12 caddy 2>/dev/null
apt-get -y autoremove --purge 2>/dev/null
rm -rf /etc/letsencrypt /etc/apache2 /etc/nginx /etc/tomcat* /etc/jetty* /etc/caddy \
       /etc/certberus /var/log/certberus /var/backups/certberus /opt/certberus
iptables -F; iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
```

The harness re-installs the patched `certberus_*_all.deb` after the reset.

---

## Group A — Apache mod_md

| ID    | Subdomain prefix | Seed state | Expected behaviour |
|-------|------------------|------------|---------------------|
| A-01  | `s001`           | clean apache2 + libapache2-mod-md; default 000-default.conf only | issuance succeeds, mod_md store has cert |
| A-02  | `s002`           | apache2 + custom :443 vhost with `SSLCertificateFile /etc/letsencrypt/live/<sub>/fullchain.pem` (pre-seed via `certbot certonly --standalone`) — replicates the oidc bug | certberus comments out hardcoded paths, mod_md issues new cert, openssl shows fresh LE staging issuer |
| A-03  | `s003`           | apache2 + custom :443 vhost with `SSLCertificateFile` pointing to a non-existent path | preflight fixes invalid path; issuance succeeds |
| A-04  | `s004`           | apache2 + custom :443 vhost where `SSLEngine on` and `SSLCertificateFile` live inside `<IfModule ssl_module>` | certberus still comments out within the IfModule; issuance succeeds |
| A-05  | `s005`           | apache2 + ONE .conf file containing TWO `<VirtualHost *:443>` blocks (one for managed sub, one for `other.<sub>` — unmanaged) | only the managed vhost's SSL* lines get commented; unmanaged vhost untouched |
| A-06  | `s006`           | apache2 + :80 vhost that redirects ALL traffic to https (no `.well-known/acme-challenge/` exemption) | certberus preflight either patches the redirect or adds a fragment to serve the challenge |
| A-07  | `s007`           | apache2 + `<Location />` + `<RequireAll>` with `Require ip 10.0.0.0/8` (so external LE probe is denied) and NO ACME exempt | preflight detects the ACL bug or certberus drops a sub-Location for /.well-known/ |
| A-08  | `s008`           | apache2; install certberus with two domains (apex + www) | SAN cert with both names |
| A-09  | `s009`           | apache2 + mod_md already enabled with a `MDomain otherdomain.example` referencing a different (unrelated) domain | certberus appends new MDomain without colliding with existing one |
| A-10  | `s010`           | apache2 installed but libapache2-mod-md package missing | certberus installs the package via apt |
| A-11  | `s011`           | apache2 NOT installed | certberus installs apache2 + mod_md, then issues |
| A-12  | `s012`           | apache2 + intentionally broken config (`syntax error` in vhost) | preflight fails clearly without touching anything; rollback not needed |
| A-13  | `s013`           | apache2 installed, systemctl disabled and stopped | certberus enables + starts apache2 |
| A-14  | `s014`           | apache2 + vhost with `ServerName S014.$CB_E2E_DEB13_WILDCARD` (uppercase) | domain matching case-insensitive; issuance succeeds |
| A-15  | `s015`           | apache2 + 3 ServerAlias entries (sub, www.sub, api.sub) | SAN with all three (only DNS-resolvable ones) |
| A-16  | `s016`           | apache2 + vhost with `Listen 443` overridden in conf-enabled (custom port file) | certberus respects custom port, issues |
| A-17  | `s017`           | apache2 + an old `.bak_*` from a previous certberus run already present | certberus creates a new backup with a fresh timestamp, does not overwrite the old |
| A-18  | `s018`           | apache2; certberus install run, succeeds; immediately run again (idempotence) | second run is a no-op, mod_md state unchanged, no duplicate MDomain |
| A-19  | `s019`           | apache2 + active certbot.timer for an unrelated domain (legacy cron renew running in background) | both coexist; certbot does not interfere with mod_md issuance |
| A-20  | `s020`           | apache2 + vhost using `SSLCertificateChainFile` directive (deprecated but legal) | also commented; mod_md serves chain itself |

## Group B — nginx + certbot

| ID    | Subdomain prefix | Seed state | Expected behaviour |
|-------|------------------|------------|---------------------|
| B-01  | `s101`           | clean nginx, default server block only | webroot detected, cert issued, ssl_certificate added |
| B-02  | `s102`           | nginx + custom server block with hardcoded `ssl_certificate /etc/letsencrypt/...` | certberus updates the existing block, no duplicate ssl_certificate |
| B-03  | `s103`           | nginx + server block with `root /var/www/example.com;` | webroot auto-detected as `/var/www/example.com`; issuance via webroot |
| B-04  | `s104`           | nginx + only `listen 443` (no `listen 80`) | certberus adds :80 listener or uses standalone certbot |
| B-05  | `s105`           | nginx NOT installed | certberus installs nginx + certbot |
| B-06  | `s106`           | nginx + server_name on apex and `*.sub` (wildcard) | only the resolvable apex name; wildcard rejected (HTTP-01 cannot do *) |
| B-07  | `s107`           | nginx + existing self-signed cert in /etc/ssl/private/sub.key+pem referenced by ssl_certificate | replaced with LE cert |
| B-08  | `s108`           | nginx + http2 enabled in default config | preserved after certberus edits |
| B-09  | `s109`           | nginx + reverse proxy block (`proxy_pass http://localhost:3000`) | proxy_pass preserved, ssl directives added |
| B-10  | `s110`           | nginx; install twice | idempotent |

## Group C — Tomcat + certbot

| ID    | Subdomain prefix | Seed state | Box |
|-------|------------------|------------|------|
| C-01  | `s201`           | tomcat9 (Debian 12) fresh, --port80 standalone | deb12 |
| C-02  | `s202`           | tomcat10 (Debian 13) fresh, --port80 standalone | deb13 |
| C-03  | `s203`           | tomcat + nginx in front, --port80 webroot --webroot /var/www/html | both |
| C-04  | `s204`           | tomcat + --port80 iptables redirect 80→8080 | both |
| C-05  | `s205`           | tomcat with existing JKS keystore + HTTPS connector already configured | both |
| C-06  | `s206`           | tomcat NOT installed | both |

## Group D — Jetty + certbot

| ID    | Subdomain prefix | Seed state | Notes |
|-------|------------------|------------|-------|
| D-01  | `s301`           | jetty12 fresh (deb13 only — bookworm has jetty9) | deb13 |
| D-02  | `s302`           | jetty9 fresh | deb12 |
| D-03  | `s303`           | jetty + Shibboleth IdP markers (/opt/shibboleth-idp dir, idp-process service unit stub) | both |
| D-04  | `s304`           | jetty + existing PKCS12 keystore at /etc/jetty12/keystore.p12 | deb13 |

## Group E — Caddy

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| E-01  | `s401`           | caddy fresh, default Caddyfile (empty) |
| E-02  | `s402`           | caddy with existing `:443 { … }` block for the test domain |
| E-03  | `s403`           | caddy NOT installed |

## Group F — certbot-only (universal)

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| F-01  | `s501`           | no webserver, --port80 standalone |
| F-02  | `s502`           | no webserver, --port80 webroot --webroot /var/www/html (dir exists) |
| F-03  | `s503`           | no webserver, --port80 webroot --webroot /var/www/missing (dir absent) — should fail clearly |
| F-04  | `s504`           | certbot already installed + has unrelated cert in /etc/letsencrypt/live/foo |

## Group G — Firewall

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| G-01  | `s601`           | apache2 + ufw enabled and blocking 80 | certberus opens the port |
| G-02  | `s602`           | apache2 + iptables explicit DROP on 80 | certberus opens, snapshot exists |
| G-03  | `s603`           | apache2 + nftables ruleset with `tcp dport 80 drop` | certberus opens |
| G-04  | `s604`           | apache2 + firewalld active (install pkg first) — public zone with no http | certberus opens via firewall-cmd |
| G-05  | `s605`           | apache2 + `--no-firewall` flag passed, port 80 blocked | install must fail cleanly (cannot reach for HTTP-01) |

## Group H — Network (no DNS mutation)

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| H-01  | `example.com`    | use a domain we provably do NOT control (LE will deny) | preflight refuses or LE order fails clearly, no partial state |
| H-04  | `s704`           | apache2 + simulated NAT (iptables SNAT to a fake public IP) + `--skip-dns-check` | issuance still succeeds when public IP != local IP |

## Group I — Configuration & input

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| I-01  | `s801`           | /etc/certberus/config.env has Unicode BOM at start |
| I-02  | `s802`           | CB_DOMAINS with leading and trailing spaces |
| I-03  | `s803`           | CB_DOMAINS with comma separator instead of space |
| I-04  | `s804`           | Domain name 63 chars long (RFC limit) |
| I-05  | `s805`           | Domain name with a hyphen at start/end (illegal) — should fail validation |
| I-06  | `s806`           | --set CB_FOO=bar with an unknown CB_* key |
| I-07  | `s807`           | config.env with shell injection attempt `CB_EMAIL="; rm -rf /;"` |
| I-08  | `s808`           | CB_ASSUME_YES=1 + `certberus interactive` | should NOT prompt |

## Group J — Chaos / failure modes

| ID    | Subdomain prefix | Seed state |
|-------|------------------|------------|
| J-01  | `s901`           | two parallel `certberus install` invocations (lock contention) — second waits or fails fast |
| J-02  | `s902`           | disk full when writing snapshot (tmpfs of 1MB at /var/backups/certberus) | clear error, no partial state |
| J-03  | `s903`           | /var/log read-only | log fallback to syslog only, no crash |
| J-04  | `s904`           | apache2 process killed mid-install | rollback restores |
| J-05  | `s905`           | clock skewed +25h | LE rejects with clear error; preflight should detect |
| J-06  | `s906`           | clock skewed −7 days | same |
| J-07  | `s907`           | 1GB RAM, 5 SAN domains | should fit; if not, clear OOM message |
| J-08  | `s908`           | reboot during install (kill via ssh `shutdown -r now`) after `Apache reload` step | next boot: certberus rollback or auto-resume |
| J-09  | `s909`           | hooks/post-issue.d/00-fail.sh that exits 1 | install marked as "issued but post-hook failed", rollback NOT triggered |
| J-10  | `s910`           | rapid renew loop (force `--force-renew` 5 times) — must respect MD renew-window |

## Group K — Production smokes

| ID    | Subdomain | CA |
|-------|-----------|-----|
| P-01  | `prod1.$CB_E2E_DEB12_WILDCARD` | LE production |
| P-02  | `prod1.$CB_E2E_DEB13_WILDCARD` | LE production |

---

## Totals

- A: 20, B: 10, C: 6, D: 4, E: 3, F: 4, G: 5, H: 2, I: 8, J: 10, P: 2 = **74 unique scenarios**
- Many run on **both** boxes (deb12 + deb13) → effective execution count ~120–140.
- For J-08 (reboot mid-install), the harness polls SSH until reachable again
  after the reboot, then probes for cert state.
