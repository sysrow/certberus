# Certberus test suite

Tier-based, industry-standard layout.

```
tests/
├── lib/                shared helpers (assert, sandbox, env)
├── unit/               pure-bash, fast, no docker, no network
├── chaos/              destructive scenarios (filesystem, network, security)
└── integration/        Docker matrix (apache/nginx/tomcat × distros)
```

## Quick start

```bash
bash tests/run-all.sh             # unit + chaos (default; no docker)
bash tests/run-all.sh --unit      # fastest tier (CI gate)
bash tests/run-all.sh --integration  # Docker matrix (slow, requires daemon)
bash tests/run-all.sh --only firewall  # run only matching test
bash tests/run-all.sh --keep-going     # continue past first failure
```

## Tiers

### `unit/` — pure-bash, must always pass

| File | What it covers |
|---|---|
| `test-syntax.sh` | `bash -n` on every `*.sh` in the repo |
| `test-cli-args.sh` | `parse_global`, `cmd_cert_info` arg routing, `--firewall`, dedup |
| `test-firewall-default.sh` | Firewall is **opt-in** (regression: example.com leak) |
| `test-mod-md-adapter.sh` | Generated `MDMessageCMD` adapter: whitelist, sanitization, auto-graceful Apache |
| `test-hooks-runtime.sh` | `cb_run_hooks` + `cb_ensure_runtime_dirs` |
| `test-bundle.sh` | Single-file bundle build + cwd-independence |
| `test-commands.sh` | `discover`, `test-domain`, `expiry`, `revoke` smoke |
| `test-discover.sh` | `lib/discover.sh` against mocked `certbot`/`dig` |
| `test-preflight.sh` | `lib/preflight.sh` + auto-rollback simulator |

### `chaos/` — destructive, pure-bash

Sims for filesystem corruption, lock contention, network failures, clock drift, hook timeouts, security boundary tests. Some need `unshare` (network namespaces); they self-skip with rc=77 if unavailable.

### `integration/` — Docker matrix

Full lifecycle in clean containers. Requires Docker daemon. Slow.

## Writing new tests

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX="$(t_mktempdir mytest)" || exit 1
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"

assert_eq "expected" "actual" "msg"
t_summary
```

### Available helpers

- `t_mktempdir [prefix]` — exec-capable tempdir (CI runners often have `/tmp` mounted `noexec`)
- `t_cleanup` — removes all dirs created by `t_mktempdir`
- `t_isolate_cb_dirs <sandbox>` — sets `CB_PREFIX`, `CB_HOOKS_DIR`, etc. inside sandbox
- `t_stub_log_helpers` — provides no-op `cb_log/warn/error/...` for tests that source `lib/*.sh`
- `t_require_tool <name>` / `t_require_docker` — graceful skip with rc=77

### Asserts

`assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`, `assert_match`, `assert_file_exists`, `assert_dir_exists`, `assert_exit_code`. All take an optional last `MESSAGE`.

### Skip codes

A test that returns rc=77 is reported as skipped, not failed. Use `t_require_*` helpers or call `t_summary` after `t_skip` and `exit 77`.

## Coverage roadmap

See [COVERAGE.md](COVERAGE.md).
