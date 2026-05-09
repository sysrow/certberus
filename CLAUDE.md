# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Certberus is a pure-bash CLI tool for automated SSL/TLS certificate deployment on Apache (mod_md), nginx (certbot), and Tomcat (certbot). It supports Let's Encrypt, HARICA/CESNET TCS, and ZeroSSL. No Python/Go/Node dependencies — just bash and standard Linux tooling.

## Language and comments

All code, comments, log messages, and user-facing strings are in English. Code identifiers (function names, variables) also use English.

## Build and test commands

```bash
# Syntax check across all shell files
for f in bin/certberus lib/*.sh webservers/*.sh; do bash -n "$f" && echo "OK: $f"; done

# Run unit tests (fast, no docker, no network)
bash tests/run-all.sh --unit

# Run unit + chaos tests (default, no docker needed)
bash tests/run-all.sh

# Run a single test by pattern
bash tests/run-all.sh --only firewall

# Run integration tests (requires Docker daemon)
bash tests/run-all.sh --integration

# Build single-file bundle
./build/bundle.sh              # produces dist/certberus

# Build all release artifacts (tarball, deb, rpm, apk, bundle — deb/rpm/apk need Docker)
bash build/build.sh all

# Sync VERSION file into bin/certberus CB_VERSION
bash build/build.sh sync-version
```

## Architecture

**Entrypoint:** `bin/certberus` — the CLI dispatcher. Parses global flags, detects the webserver, delegates to webserver-specific scripts. This file also contains all top-level commands (status, doctor, discover, expiry, scan, etc.).

**Libraries (`lib/`):** Sourced by `bin/certberus` at startup. All public functions use the `cb_` prefix, private functions use `_cb_`.

- `common.sh` — logging (file + syslog + stdout), TTY helpers, config loading, snapshot/rollback, input validation, service management, retry wrappers. Loaded first; all other libs depend on it.
- `os.sh` — OS detection (distro, version, package manager)
- `dns.sh` — DNS resolution and domain-points-here checks
- `firewall.sh` — auto-detect and manage firewalld/ufw/nftables/iptables
- `hooks.sh` — run-parts style hook execution + mod_md MDMessageCMD adapter
- `discover.sh` — domain auto-discovery from webserver configs, certbot, mod_md store, HTTPS listeners
- `scan.sh` — X.509 inventory scanner (filesystem, configs, TLS listeners)
- `preflight.sh` — pre-issue validation checks

**Webserver modules (`webservers/`):** Each is a standalone script spawned as a subprocess by the orchestrator. They receive forwarded CLI args via `build_forward_args()`.

- `apache-md.sh` — Apache mod_md for Let's Encrypt (Debian/Ubuntu + RHEL/Fedora)
- `apache-md-eab.sh` — Apache mod_md with EAB (HARICA/ZeroSSL)
- `nginx-certbot.sh` — nginx with certbot (webroot auto-detected from nginx config, all OS)
- `tomcat-certbot.sh` — Tomcat 9+ with certbot (all OS)
- `jetty-certbot.sh` — Jetty with certbot + PKCS12 keystore conversion (detects Shibboleth IdP as special case)
- `caddy.sh` — Caddy native ACME (no certbot, like Apache mod_md pattern)
- `certbot-only.sh` — universal module (standalone or webroot, works on all OS including RHEL/Fedora)

**Bundle (`build/bundle.sh`):** Produces a single self-extracting bash file (`dist/certberus`) that embeds all lib/*.sh and webservers/*.sh as heredoc payloads, extracts to a tmpdir at runtime, and cleans up on exit.

## Key conventions

- Guard against double-sourcing: each lib starts with `[[ -n "${_CB_<NAME>_LOADED:-}" ]] && return 0`
- Config lives in `/etc/certberus/config.env` (CB_* variables). CLI flags override config via `cb_apply_cli_set`.
- All mutative commands (issue/renew/rollback/revoke) take an exclusive `flock` on `/var/lock/certberus.lock`.
- Snapshots are atomic: tar to `.partial`, then `mv` to final name.
- Version is tracked in two places: `build/VERSION` (source of truth for builds) and `CB_VERSION` in `bin/certberus` (synced by `build/build.sh sync-version`).

## Test conventions

Tests live in `tests/` with three tiers: `unit/` (fast, pure bash), `chaos/` (destructive scenarios, may need `unshare`), `integration/` (Docker matrix). Exit code 77 = skip (not failure). Test helpers are in `tests/lib/assert.sh` and `tests/lib/env.sh`. Use `t_isolate_cb_dirs` to sandbox CB_* paths.

## Release process

Push a `v*` tag to trigger `.github/workflows/release.yml`, which builds all formats in parallel, runs smoke tests, and creates a GitHub Release with checksums.
