# Certberus — vysledky testovani

Posledni aktualizace: 2026-05-09
Verze: 0.1.17

## Testovane platformy

| OS | Verze | Arch | IP | DNS | Vysledek |
|----|-------|------|----|-----|----------|
| Rocky Linux | 10.0 | x86_64 | <ip> | *.example.com | **PASS** (32/34, 2 false-fail) |
| CentOS Stream | 10 | x86_64 | <ip> | *.centos.example.com | **PASS** (19/19) |
| AlmaLinux | 10.1 | x86_64 | <ip> | *.alma.example.com | **PASS** (19/19) |
| Rocky Linux | 10.0 | x86_64 | <ip> | *.rocky.example.com | **PASS** (19/19) |
| Ubuntu | 25.10 | x86_64 | <ip> | *.ubuntu.example.com | **PASS** (18/18) |
| Debian | 13 | x86_64 | example.com | — | **PASS** (11/12, /tmp noexec) |

### Untested platforms

- Debian 10/11/12 (pouze Debian 13 na example.com)
- Fedora (certbot by mel byt primo v repech)
- openSUSE / SLES (zypper backend)
- Alpine (apk backend)
- ARM / aarch64

## Tested commands and features

### Basic commands (all OS)

| Prikaz | Status |
|--------|--------|
| `certberus version` | PASS |
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
| Flags before command (`--staging --verbose --yes help`) | PASS |
| Unknown command → exit 2 | PASS |

### Modules

| Modul | OS | Status | Poznamka |
|-------|----|--------|----------|
| certbot-only (standalone) | Rocky, CentOS, Alma, Ubuntu, Debian | PASS | LE staging certy vydany na vsech |
| certbot-only (webroot) | Ubuntu | PASS | |
| certbot-only (port 80 obsazeny, bez webroot) | Ubuntu | PASS (spravne odmitne) | |
| nginx-certbot | Ubuntu 25.10 | PASS | nginx auto-install, cert issue, reload |
| apache-md | Ubuntu 24.04 (drive) | PASS s workaroundem | BUG #4 opraven |
| tomcat-certbot | — | NETESTOVANO | Ubuntu droplet spadl |
| apache-md-eab | — | NETESTOVANO | Vyzaduje HARICA + Apache |

### HARICA / CESNET TCS (EAB)

| Test | OS | Status |
|------|----|--------|
| HARICA dry-run (example.com, --skip-dns-check) | Rocky, CentOS, Alma, Rocky NYC, Ubuntu, Debian | **PASS vsude** |
| HARICA real cert (example.com) | Debian 13 (example.com) | PASS — issuer GEANT TLS ECC 1 |
| HARICA ne-ZCU domena (example.com) | Rocky | Spravne odmitne ("Identifiers could not be parsed") |
| EAB credentials v config.env persist | Rocky, Debian | PASS |

**Poznamka:** HARICA/CESNET TCS validuje domeny na urovni organizace (ne HTTP-01).
Pro pouziti je VZDY nutne `--skip-dns-check`, protoze domena nemusi smerovat na server.

### Hook system

| Test | OS | Status |
|------|----|--------|
| Post-issue hook se spusti | Rocky, CentOS, Alma, Rocky NYC, Ubuntu | PASS |
| CA_SOURCE=certbot v hooku | Vsude | PASS |
| CA_EVENT=post-issue | Vsude | PASS |
| CA_WEBSERVER=certbot-only | Vsude | PASS |
| CA_STAGING=1 (staging mode) | Rocky | PASS |
| CA_CERT_ISSUER=letsencrypt | Rocky | PASS |
| Hook timeout (CB_HOOK_TIMEOUT=3) | Rocky | PASS |
| Hooks list filtruje .disabled/.bak | Rocky | PASS |
| Renewed.d hook (certbot renewal) | Rocky | PASS (deploy hook instalovan) |
| PKCS12 konverze hook (Jetty/Shibboleth) | Rocky | PASS — owner jetty, mode 600, spravny subject |

### Error paths

| Test | OS | Status |
|------|----|--------|
| Apache na Rocky/CentOS/Alma (OS guard) | Vsechny RHEL | PASS — "neni podporovan" |
| Nginx na Rocky/CentOS/Alma (OS guard) | Vsechny RHEL | PASS — "neni podporovan" |
| Chybejici email | Rocky | PASS — "Chybi platny email" |
| Domain merge z config.env | Rocky | PASS — stare domeny se nemisi |
| Multi-domain (2-3 SANs) | Rocky, CentOS, Alma, Rocky NYC, Ubuntu | PASS |
| Flock (soucastny beh) | Rocky | PASS — druhy proces blokovany |
| Dry-run neretryuje cert-file check | Rocky, Debian | PASS |

### Firewall

| Test | OS | Status |
|------|----|--------|
| Firewalld detekce | Rocky FRA1 | PASS |
| Firewalld auto-open port 80/443 | Rocky FRA1 | PASS |
| UFW detekce | Ubuntu (drive) | PASS (ale lockout risk) |
| nftables detekce | Debian 13 (example.com) | PASS |
| iptables detekce | Ubuntu 25.10 | PASS |
| --firewall flag | Rocky | PASS |
| --no-firewall flag | Rocky | PASS |

### Bundle

| Test | OS | Status |
|------|----|--------|
| Bundle build + syntax | Vsude | PASS |
| Bundle version match | Vsude | PASS |
| Payload extraction (lib/*.sh) | Vsude | PASS |
| Payload extraction (webservers/*.sh) | Vsude | PASS |
| /tmp noexec fallback na /var/tmp | Debian 13 (example.com) | PASS |
| Subprocess (webserver modul) z bundle | Vsude | PASS |

### Staging → Production transition

| Test | OS | Status |
|------|----|--------|
| Detekce staging certu, force-renewal | Rocky FRA1 | PASS |
| Produkcni LE cert (issuer E8) | Rocky FRA1 | PASS |

### SELinux

| Test | OS | Status |
|------|----|--------|
| SELinux Enforcing + targeted | Rocky FRA1 | PASS — vsechny operace fungujou |

## Unit tests

```
16 testu, 16 pass, 0 fail, 0 skip (75s)

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

## Nalezene a opravene chyby

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

## Zname limitace

1. **Tomcat modul** (tomcat-certbot.sh) — nebyl testovan na zadnem dropletu (Ubuntu spadl drive)
2. **Apache mod_md EAB** (apache-md-eab.sh) — netestovano (vyzaduje HARICA + Apache, apache moduly povoleny jen na Debian/Ubuntu)
3. **Alpine/openSUSE** — apk/zypper backendy existuji v kodu, ale nebyly testovany na realnem HW
4. **ARM/aarch64** — netestovano
5. **UFW firewall** — detekce funguje, ale auto-open zpusobil SSH lockout na Ubuntu (nut pouzit opatrne)
6. **Config.env placeholder** — stary install.sh generoval `CB_ACME_URL` s placeholder `....` (ne komentovany). `cb_sanitize_acme_url` to chyti, ale je treba zajistit ze novy install.sh to negeneruje.
