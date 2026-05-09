# Certberus — vysledky testovani

Posledni aktualizace: 2026-05-09
Verze: 0.1.17

## Testovane platformy

| OS | Verze | Arch | IP | DNS | Vysledek |
|----|-------|------|----|-----|----------|
| Rocky Linux | 8.8 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, 3-SAN, hooks, prod cert) |
| Rocky Linux | 9.2 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, rollback hook) |
| AlmaLinux | 8.10 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, firewalld) |
| AlmaLinux | 9.7 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, rollback, --no-firewall) |
| CentOS Stream | 9 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, HARICA validation) |
| Fedora | 42 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only, 2-SAN, prod cert) |
| Fedora | 43 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only) |
| Debian | 12 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only) |
| Debian | 13 | x86_64 | <ip> | *.example.com | **PASS** (nginx, apache-md, tomcat, certbot-only, hooks) |
| Ubuntu | 22.04 LTS | x86_64 | <ip> | *.example.com | **PASS** (nginx, certbot-only) |
| Ubuntu | 24.04 LTS | x86_64 | <ip> | *.example.com | **PASS** (apache-md, tomcat, certbot-only) |
| Ubuntu | 25.10 | x86_64 | <ip> | *.example.com | **PASS** (certbot-only) |
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

| Modul | OS | Status | Poznamka |
|-------|----|--------|----------|
| certbot-only (standalone) | Vsechny (12 serveru) | PASS | LE staging certy vydany na vsech |
| certbot-only (webroot) | Ubuntu 22.04 | PASS (drive) | |
| certbot-only (port 80 obsazeny, bez webroot) | Ubuntu 22.04 | PASS (spravne odmitne) | |
| nginx-certbot | Debian 13, Ubuntu 22.04 | PASS | nginx auto-install, cert, reload |
| apache-md | Debian 13, Ubuntu 24.04 | PASS | mod_md async polling, cert v domains/ |
| tomcat-certbot | Debian 13, Ubuntu 24.04 | **PASS** | **PRVNI REAL HW TEST** — server.xml, HTTPS :443 |
| apache-md-eab | — | NETESTOVANO | Vyzaduje HARICA + Apache |

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
| SELinux Enforcing — vsechny operace | Rocky 8, Rocky 9, Alma 8, Alma 9, CentOS 9, Fedora 42, Fedora 43 | PASS |
| Zadne AVC denials (ausearch) | Vsechny RHEL (7 serveru) | PASS — 0 AVCs |
| getenforce stale Enforcing | Vsechny RHEL | PASS |

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
| Detekce staging certu, force-renewal | Rocky 8, Fedora 42 | PASS |
| Produkcni LE cert (issuer R12) | Rocky 8 | PASS |
| Produkcni LE cert (issuer E7) | Fedora 42 | PASS |

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
| 3 | nginx ACME webroot 0700 (www-data 403) | `webservers/nginx-certbot.sh:131` | `chmod 0755` po mkdir |
| 4 | mod_md polling jen staging/, ne domains/ | `webservers/apache-md.sh` | Poll obe cesty + extra graceful |
| 5 | `cmd_rollback` unbound variable `$last` | `bin/certberus:979,986` | `local last=""` + certbot-only pattern ve find |
| 6 | certbot-only ignoruje --firewall | `webservers/certbot-only.sh` | Pridan `stage_firewall` s `cb_firewall_ensure_http_https` |

### v0.1.16 (4 opravy)

| # | Popis | Soubor | Oprava |
|---|-------|--------|--------|
| 7 | `cmd_hooks` ukazuje .disabled/.bak soubory | `bin/certberus` | find -executable + ! -name filtr |
| 8 | `doctor` bez curl pada (cb_server_ipv4/v6) | `lib/dns.sh` | `command -v curl` guard |
| 9 | scan vraci exit code 1 | `lib/scan.sh`, `bin/certberus` | Explicitni `return 0` |
| 10 | Domain merge z config.env (stare CB_DOMAINS) | `bin/certberus` | `build_forward_args` resetuje CB_DOMAINS pri CLI --domain |

### v0.1.17 (5 oprav)

| # | Popis | Soubor | Oprava |
|---|-------|--------|--------|
| 11 | CA_SOURCE nepropaguje do hooku | `lib/hooks.sh`, `webservers/*.sh` | Export v cb_run_hooks/cb_hook_context/cb_hook_set_cert + explicitni export v modulech |
| 12 | Dry-run retryuje 3x (cert file neexistuje) | `lib/common.sh` | `cb_certbot_issue` preskoci file check pri dry-run |
| 13 | Bundle pada na /tmp noexec | `build/bundle.sh` | Fallback /var/tmp → /tmp s exec test |
| 14 | EPEL neni auto-enablovano (RHEL/CentOS/Alma/Rocky) | `lib/os.sh` | `cb_pkg_install` automaticky `dnf install epel-release` |
| 15 | cmd_auto nepersistuje EAB credentials do config.env | `bin/certberus` | Predani CLI_EAB_KID/HMAC/ACME_URL do `cb_persist_config_skeleton` |

### Pozorovani z tohoto testu (zadne nove bugy)

| # | Popis | Hodnoceni |
|---|-------|-----------|
| — | DNS round-robin (*.example.com → 12 IP) zpusobuje selhani LE HTTP-01 challenge | Neni bug certberus — LE musi dosahnout presnou IP. Reseno socat forwardingem pri testovani. |
| — | 1GB RAM servery (Rocky 9, Alma 9, CentOS 9) OOM pri `dnf install certbot` | Neni bug — nedostatek RAM. Reseno pridanim swapu. |
| — | HARICA EAB credentials jsou single-use pro registraci uctu | Neni bug certberus — HARICA ACME server chrani EAB pred znovupouzitim. |
| — | Config.env z HARICA testu (CB_CA=harica, CB_ACME_URL) pretrvava a ovlivni dalsi beh s --staging | Potencialni UX problem. CLI --staging by mel ignorovat CB_ACME_URL z config.env kdyz neni --ca harica. |

## Zname limitace

1. **Apache mod_md EAB** (apache-md-eab.sh) — netestovano (vyzaduje HARICA + Apache, apache moduly povoleny jen na Debian/Ubuntu)
2. **openSUSE / SLES** — zypper backend existuje v kodu, ale nebyl testovan na realnem HW
3. **Alpine** — apk backend existuje v kodu, ale nebyl testovan
4. **ARM / aarch64** — netestovano
5. **UFW firewall** — detekce funguje, ale auto-open zpusobil SSH lockout na Ubuntu (drive)
6. **Config.env placeholder** — stary install.sh generoval `CB_ACME_URL` s placeholder `....` (ne komentovany). `cb_sanitize_acme_url` to chyti.

## Celkovy souhrn

| Metrika | Hodnota |
|---------|---------|
| Testovanych platforem | 12 (+ 5 z drivejska = 17 celkem) |
| Novych platforem | Fedora 42, Fedora 43, Rocky 8, Alma 8/9, Debian 12 |
| Unikatnich OS verzi | 10 |
| Staging certu vydano | 14 |
| Produkcnich certu vydano | 2 (Rocky 8, Fedora 42) |
| Tomcat modulu otestovano | 2 (Debian 13, Ubuntu 24.04) — PRVNI REAL HW TEST |
| SELinux Enforcing serveru | 7 (vsechny RHEL, 0 AVC denials) |
| Hook testu | 11 (post-issue, timeout, filtering, on-rollback) |
| Firewall backendu otestovano | 4 (iptables legacy, iptables nf_tables, firewalld, nftables) |
| Unit testu | 16 pass, 0 fail |
| Chaos testu | 7 pass |
| Novych bugu nalezeno | 0 |
