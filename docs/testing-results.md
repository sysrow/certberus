# Certberus — Testing Results

Last updated: 2026-05-09
Version: 0.1.18

## Tested platforms

| OS | Version | Arch | IP | DNS | Result |
|----|---------|------|----|-----|--------|
| Rocky Linux | 8.8 | x86_64 | <ip> | *.rocky8.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| Rocky Linux | 9.2 | x86_64 | <ip> | *.rocky9.example.com | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| Rocky Linux | 10.0 | x86_64 | <ip> | *.rocky10.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| AlmaLinux | 8.10 | x86_64 | <ip> | *.alma8.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| AlmaLinux | 9 | x86_64 | <ip> | *.alma9.example.com | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| AlmaLinux | 10 | x86_64 | <ip> | *.alma10.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| CentOS Stream | 9 | x86_64 | <ip> | *.centos9.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| CentOS Stream | 10 | x86_64 | <ip> | *.centos10.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| Fedora | 42 | x86_64 | <ip> | *.fedora42.example.com | **PASS** (all 6 modules, SELinux Enforcing+Permissive) |
| Fedora | 43 | x86_64 | <ip> | *.fedora43.example.com | **PASS** (all 6 modules, SELinux Enforcing) |
| Debian | 12 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, nginx-certbot, prod cert, ext. SSL ✓) |
| Debian | 13 | x86_64 | <ip> | *.example.com | **PASS** (nginx, apache-md, tomcat, certbot-only, hooks, prod cert, ext. SSL ✓) |
| Ubuntu | 22.04 LTS | x86_64 | <ip> | *.example.com | **PASS** (nginx, certbot-only) |
| Ubuntu | 24.04 LTS | x86_64 | <ip> | *.example.com | **PASS** (apache-md, tomcat, certbot-only) |
| Ubuntu | 25.10 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, nginx-certbot, prod cert, ext. SSL ✓) |
| Debian | 13 | x86_64 | example.com | — | **PASS** (HARICA real cert, /tmp noexec) |
| Rocky Linux | 10.0 | x86_64 | — | — | **PASS** (previous testing v0.1.15-v0.1.17) |
| CentOS Stream | 10 | x86_64 | — | — | **PASS** (previous testing) |
| AlmaLinux | 10.1 | x86_64 | — | — | **PASS** (previous testing) |
| Ubuntu | 25.10 | x86_64 | — | — | **PASS** (previous testing) |

### Untested platforms

- openSUSE / SLES (zypper backend)
- Alpine (apk backend)
- ARM / aarch64

## Tested commands and features

### Basic commands (all OS)

| Command | Status |
|---------|--------|
| `certberus version` | PASS (12 servers) |
| `certberus help` | PASS |
| `certberus status` | PASS |
| `certberus doctor` | PASS |
| `certberus expiry` | PASS |
| `certberus logs N` | PASS |
| `certberus snapshots` | PASS |
| `certberus discover` | PASS |
| `certberus hooks list` | PASS |
| `certberus cert-info` (summary) | PASS |
| `certberus cert-info DOMAIN` (detail) | PASS |
| `certberus scan --format tsv` | PASS |
| `certberus scan --format json` | PASS |
| `certberus scan --no-fs` | PASS |
| `certberus scan --no-fs --no-config` | PASS |
| `certberus test-domain DOMAIN` (local) | PASS |
| `certberus test-domain DOMAIN` (remote) | PASS |
| `certberus renew` | PASS |
| `certberus rollback --dry-run` | PASS |
| `certberus rollback -y` | PASS |
| Flags before command (`--staging --verbose --yes help`) | PASS |
| Unknown command → exit 2 | PASS |

### Modules

| Module | OS | Status | Note |
|--------|----|--------|------|
| certbot-only (standalone) | All (12 servers) | PASS | LE staging certs issued on all |
| certbot-only (webroot) | Ubuntu 22.04 | PASS (earlier) | |
| certbot-only (port 80 occupied, no webroot) | Ubuntu 22.04 | PASS (correctly rejects) | |
| nginx-certbot | Debian 12, Debian 13, Ubuntu 22.04, Ubuntu 25.10 | PASS | nginx auto-install, cert, reload. Refactored: auto-detect nginx root, /var/www/acme removed. |
| apache-md | Debian 13, Ubuntu 24.04 | PASS | mod_md async polling, cert in domains/ |
| tomcat-certbot | Debian 13, Ubuntu 24.04 | **PASS** | **FIRST REAL HW TEST** — server.xml, HTTPS :443 |
| apache-md-eab | — | NOT TESTED | Requires HARICA + Apache |

### HARICA / CESNET TCS (EAB)

| Test | OS | Status |
|------|----|--------|
| HARICA dry-run (example.com, --skip-dns-check) | All (earlier) | PASS |
| HARICA real cert (example.com) | Debian 13 (example.com) | PASS — issuer GEANT TLS ECC 1 |
| HARICA non-ZCU domain (example.com) | Rocky | Correctly rejects |
| EAB credentials in config.env persist | Rocky, Debian | PASS |
| HARICA validation without EAB → error | CentOS | PASS — correctly requires EAB |
| HARICA without ACME_URL → error | CentOS | PASS — correctly requires URL |

### Hook system

| Test | OS | Status |
|------|----|--------|
| Post-issue hook fires | Rocky 8 | PASS |
| CA_SOURCE=certbot in hook | Rocky 8 | PASS |
| CA_EVENT=post-issue | Rocky 8 | PASS |
| CA_WEBSERVER=certbot-only | Rocky 8 | PASS |
| CA_STAGING=1 (staging mode) | Rocky 8 | PASS |
| CA_CERT_ISSUER=letsencrypt | Rocky 8 | PASS |
| CA_CERT_PATH + CA_KEY_PATH | Rocky 8 | PASS — point to real files |
| Hook timeout (CB_HOOK_TIMEOUT=3) | Rocky 8 | PASS — log: "Hook timeout (>3s)" |
| Hooks list filters .disabled/.bak | Rocky 8 | PASS |
| on-rollback hook | Rocky 9 | PASS |
| Renewed.d hook (certbot renewal) | All | PASS (deploy hook installed) |

### Error paths

| Test | OS | Status |
|------|----|--------|
| Apache on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS — "not supported" |
| Nginx on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS |
| Tomcat on RHEL family (OS guard) | Rocky 8/9, Alma 8/9, CentOS 9, Fedora 42/43 | PASS |
| certbot-only passes OS guard | All RHEL | PASS |
| Missing email | Fedora 42 | PASS — "Missing valid email" |
| Invalid domain | Debian 13 | PASS |
| Invalid email | Ubuntu 22.04 | PASS |
| Multi-domain (2-3 SANs) | Rocky 8, Fedora 42, Ubuntu 22.04 | PASS |
| Flock (concurrent run) | Rocky 8 | PASS — second process blocked |
| Port 80 occupied without webroot | Ubuntu 22.04 | PASS — correctly rejects |

### Firewall

| Test | OS | Status |
|------|----|--------|
| Firewalld detection | AlmaLinux 8 | PASS (iptables nf_tables backend) |
| iptables (legacy) detection | Fedora 42 | PASS |
| iptables (nf_tables) detection | Debian 13, Ubuntu 22/24 | PASS |
| nftables detection | Fedora 42 (via iptables wrapper) | PASS |
| No firewall detection | Rocky 8/9, Alma 9, CentOS 9 | PASS |
| --firewall auto-open port 80/443 | AlmaLinux 8 | PASS |
| --no-firewall flag | AlmaLinux 9 | PASS — no FW messages |

### SELinux

| Test | OS | Status |
|------|----|--------|
| SELinux Enforcing — all operations (6 modules) | All RHEL (10 servers) | PASS |
| No AVC denials (ausearch) | All RHEL (10 servers) | PASS — 0 AVCs |
| getenforce still Enforcing | All RHEL | PASS |
| httpd_can_network_connect auto-enable | All RHEL (apache module) | PASS |
| restorecon after mktemp+mv | All RHEL (apache module) | PASS |
| SELinux Permissive vs Enforcing comparison | Rocky 9, Alma 9, Fedora 42 | PASS — identical result |

### Bundle

| Test | OS | Status |
|------|----|--------|
| Bundle build + syntax | Local | PASS |
| Bundle deploy on 12 servers | All | PASS |
| Bundle version match | All | PASS (0.1.17) |
| Payload extraction (lib/*.sh) | All | PASS |
| Payload extraction (webservers/*.sh) | All | PASS |
| /tmp noexec fallback to /var/tmp | Debian 13 (example.com) | PASS |

### Staging → Production transition

| Test | OS | Status |
|------|----|--------|
| Staging cert detection, force-renewal | Rocky 8, Fedora 42 | PASS |
| Production LE cert (issuer R12) | Rocky 8 | PASS |
| Production LE cert (issuer E7) | Fedora 42, Debian 12, Debian 13 | PASS |
| Production LE cert (issuer E8) | Ubuntu 25.10 | PASS |

### End-to-end external verification (openssl s_client from example.com)

| Server | Domain | Cert | Verify return code |
|--------|--------|------|--------------------|
| Rocky 8 | r8-prod.example.com | LE R12 (prod) | **0 (ok)** |
| Fedora 42 | f42-prod.example.com | LE E7 (prod) | **0 (ok)** |
| Debian 12 | d12-prod.example.com | LE E7 (prod) | **0 (ok)** |
| Debian 13 | d13-prod.example.com | LE E7 (prod) | **0 (ok)** |
| Ubuntu 25.10 | u25-prod.example.com | LE E8 (prod) | **0 (ok)** |
| Rocky 8 | r8-e2e-full.example.com | LE staging | accessible |
| Fedora 42 | f42-e2e-full.example.com | LE staging | accessible |
| Debian 12 | d12-nginx-e2e.example.com | LE staging | accessible |
| Ubuntu 25.10 | u25-nginx-e2e.example.com | LE staging | accessible |

### EPEL auto-install

| Test | OS | Status |
|------|----|--------|
| EPEL auto-install (yum) | Rocky 8 | PASS — epel-release-8-22.el8 |
| EPEL auto-install (dnf) | Rocky 9, Alma 8, Alma 9, CentOS 9 | PASS |
| Fedora: certbot from base repos, WITHOUT EPEL | Fedora 42 (certbot 3.3.0), Fedora 43 (certbot 4.1.1) | PASS |

### Rollback and snapshots

| Test | OS | Status |
|------|----|--------|
| Snapshot created on issue | All | PASS |
| certberus snapshots | All | PASS |
| certberus rollback --dry-run | Rocky 9 | PASS |
| certberus rollback -y | Alma 9, Rocky 9 | PASS |
| on-rollback hook fires | Rocky 9 | PASS |

## Unit tests

```
16 tests, 16 pass, 0 fail, 0 skip (81s)

  test-bundle              27 pass
  test-certbot-renewal     35 pass
  test-cli-args            18 pass
  test-commands            70 pass
  test-common              92 pass
  test-discover            26 pass
  test-dns-os              47 pass (2 skip)
  test-firewall            75 pass
  test-firewall-default     5 pass
  test-hooks-deploy-integ  27 pass
  test-hooks-lifecycle     37 pass
  test-hooks-runtime       22 pass
  test-mod-md-adapter      27 pass
  test-preflight           11 pass
  test-scan                17 pass
  test-syntax              52 pass
```

## Chaos tests

7 chaos tests, all pass (part of `run-all.sh` default run, 23 tests total).

## Bugs found and fixed (earlier)

### v0.1.15 (6 bugs)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 1 | Domain duplication (`-d x -d x`) | `bin/certberus`, `webservers/certbot-only.sh` | Dedup in `stage_find_domains` |
| 2 | `cb_pkg_installed` false positive (dpkg deinstall state) | `lib/os.sh:82` | `dpkg-query -W -f='${Status}'` + grep "install ok installed" |
| 3 | nginx ACME webroot 0700 (www-data 403) | `webservers/nginx-certbot.sh:131` | `chmod 0755` after mkdir |
| 4 | mod_md polling only staging/, not domains/ | `webservers/apache-md.sh` | Poll both paths + extra graceful |
| 5 | `cmd_rollback` unbound variable `$last` | `bin/certberus:979,986` | `local last=""` + certbot-only pattern in find |
| 6 | certbot-only ignores --firewall | `webservers/certbot-only.sh` | Added `stage_firewall` with `cb_firewall_ensure_http_https` |

### v0.1.16 (4 fixes)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 7 | `cmd_hooks` shows .disabled/.bak files | `bin/certberus` | find -executable + ! -name filter |
| 8 | `doctor` without curl crashes (cb_server_ipv4/v6) | `lib/dns.sh` | `command -v curl` guard |
| 9 | scan returns exit code 1 | `lib/scan.sh`, `bin/certberus` | Explicit `return 0` |
| 10 | Domain merge from config.env (old CB_DOMAINS) | `bin/certberus` | `build_forward_args` resets CB_DOMAINS on CLI --domain |

### v0.1.17 (5 fixes)

| # | Description | File | Fix |
|---|-------------|------|-----|
| 11 | CA_SOURCE not propagated to hook | `lib/hooks.sh`, `webservers/*.sh` | Export in cb_run_hooks/cb_hook_context/cb_hook_set_cert + explicit export in modules |
| 12 | Dry-run retries 3x (cert file does not exist) | `lib/common.sh` | `cb_certbot_issue` skips file check on dry-run |
| 13 | Bundle crashes on /tmp noexec | `build/bundle.sh` | Fallback /var/tmp → /tmp with exec test |
| 14 | EPEL not auto-enabled (RHEL/CentOS/Alma/Rocky) | `lib/os.sh` | `cb_pkg_install` automatically `dnf install epel-release` |
| 15 | cmd_auto does not persist EAB credentials to config.env | `bin/certberus` | Pass CLI_EAB_KID/HMAC/ACME_URL to `cb_persist_config_skeleton` |

### v0.1.18 — RHEL full modules + Jetty + Caddy (8 fixes)

E2E testing of all 6 webserver modules on 10 RHEL-family servers (60 combinations).

| # | Description | File | Fix |
|---|-------------|------|-----|
| 17 | `apachectl -M` returns "not supported" on el9+ | `webservers/apache-md.sh` | `_cb_apache_list_modules()` fallback: apachectl → httpd → apache2ctl |
| 18 | `MDContactEmail` does not exist in mod_md < 2.4.0 (el8 has 2.0.8) | `webservers/apache-md.sh` | mod_md version detection, conditional `_APACHE_MD_HAS_CONTACT_EMAIL` |
| 19 | SELinux `user_tmp_t` on certberus-ssl.conf (mktemp+mv) | `webservers/apache-md.sh`, `lib/preflight.sh` | `restorecon` after `mv` of stub vhost and fallback cert |
| 20 | SELinux `httpd_can_network_connect off` blocks mod_md ACME | `webservers/apache-md.sh` | `stage_selinux()` — `setsebool -P httpd_can_network_connect on` |
| 21 | nginx webroot depth detection hardcoded depth==1 | `webservers/nginx-certbot.sh` | Relative depth tracking against server block depth (`sd=depth`) |
| 22 | nginx reload on inactive service | `webservers/nginx-certbot.sh` | `cb_svc_is_active nginx \|\| cb_svc_start nginx` before reload |
| 23 | Tomcat certbot always --webroot, even when webroot empty | `webservers/tomcat-certbot.sh` | Standalone fallback when `TOMCAT_ACME_WEBROOT` empty; webroot via Tomcat webapps/ROOT |
| 24 | `grep -q` + `set -o pipefail` → SIGPIPE (rc=141) | all webserver modules, `bin/certberus` | `grep ... >/dev/null` instead of `grep -q` for all `systemctl \| grep` |
| 25 | Jetty ssl.ini commented lines match grep | `webservers/jetty-certbot.sh` | `stage_inject_jetty_ssl()` — grep uncommented lines only, append full config |

#### RHEL module E2E matrix (10 servers x 6 modules = 60 tests)

| OS | certbot-only | Apache (mod_md) | nginx (certbot) | Tomcat (certbot) | Caddy (native) | Jetty (certbot) | SELinux |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Rocky Linux 8 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Rocky Linux 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Rocky Linux 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 8 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| AlmaLinux 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| CentOS Stream 9 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| CentOS Stream 10 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Fedora 42 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |
| Fedora 43 | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | **PASS** | Enforcing |

SELinux Permissive comparison (rocky9, alma9, fedora42): Apache works identically in Enforcing and Permissive — no AVC denials.

#### Servers

| Server | IP | DNS |
|--------|-----|-----|
| Rocky 8 | <ip> | *.rocky8.example.com |
| Rocky 9 | <ip> | *.rocky9.example.com |
| Rocky 10 | <ip> | *.rocky10.example.com |
| AlmaLinux 8 | <ip> | *.alma8.example.com |
| AlmaLinux 9 | <ip> | *.alma9.example.com |
| AlmaLinux 10 | <ip> | *.alma10.example.com |
| CentOS Stream 9 | <ip> | *.centos9.example.com |
| CentOS Stream 10 | <ip> | *.centos10.example.com |
| Fedora 42 | <ip> | *.fedora42.example.com |
| Fedora 43 | <ip> | *.fedora43.example.com |

### Observations from this testing

| # | Description | Assessment |
|---|-------------|------------|
| — | DNS round-robin (*.example.com → 12 IP) causes LE HTTP-01 challenge failure | Not a certberus bug — LE must reach the exact IP. Resolved with socat forwarding during testing. |
| — | 1GB RAM servers (Rocky 9, Alma 9, CentOS 9) OOM on `dnf install certbot` | Not a bug — insufficient RAM. Resolved by adding swap. |
| — | HARICA EAB credentials are single-use for account registration | Not a certberus bug — HARICA ACME server protects EAB from reuse. |
| — | Config.env from HARICA test (CB_CA=harica, CB_ACME_URL) persists and affects next run with --staging | Potential UX issue. CLI --staging should ignore CB_ACME_URL from config.env when --ca harica is not set. |
| **16** | **Ubuntu 25.10: /var/www has permissions 700** — nginx worker (www-data) cannot read webroot for ACME challenge. `nginx-certbot` module creates `/var/www/acme` but does not verify traversability of the parent directory. | **FIXED** — refactored: module now auto-detects nginx document root from `nginx -T`, uses standard `/var/www/html` (fallback). `/var/www/acme` + snippet approach removed. Migration code cleans up remnants from <=0.1.16. E2E verified: Debian 12, Ubuntu 25.10. |

## Known limitations

1. **Apache mod_md EAB** (apache-md-eab.sh) — not tested (requires HARICA + Apache)
2. **openSUSE / SLES** — zypper backend exists in code but was not tested on real hardware
3. **Alpine** — apk backend exists in code but was not tested
4. **ARM / aarch64** — not tested
5. **UFW firewall** — detection works, but auto-open caused SSH lockout on Ubuntu (earlier)
6. **Config.env placeholder** — old install.sh generated `CB_ACME_URL` with placeholder `....` (not commented). `cb_sanitize_acme_url` catches it.

## Overall summary

| Metric | Value |
|--------|-------|
| Tested platforms | 17 (12 Debian/Ubuntu/RHEL + 5 previous) |
| RHEL-family modules E2E | 60/60 PASS (10 servers x 6 modules) |
| New platforms in this round | Rocky 10, AlmaLinux 10, CentOS Stream 10 |
| Unique OS versions | 13 |
| Staging certs issued | 81 (21 previous + 60 new) |
| Production certs issued | 5 (Rocky 8, Fedora 42, Debian 12, Debian 13, Ubuntu 25.10) |
| Ext. SSL verification (Verify: 0 ok) | 5/5 production, 4/4 staging |
| SELinux Enforcing servers | 10 (all RHEL, 0 AVC denials) |
| SELinux Permissive comparison | 3 (rocky9, alma9, fedora42) — identical result |
| Hook tests | 11 (post-issue, timeout, filtering, on-rollback) |
| Firewall backends tested | 4 (iptables legacy, iptables nf_tables, firewalld, nftables) |
| Unit tests | 16 pass, 0 fail |
| Chaos tests | 7 pass |
| New bugs found in v0.1.18 | 9 (#17-#25: Apache SELinux/RHEL, nginx depth, Tomcat standalone, Jetty ssl.ini, SIGPIPE) |
