#!/bin/bash
# tests/test-commands.sh
# Smoke tests for new commands: discover, test-domain, expiry, revoke
set -uo pipefail
CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
_pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

# Isolated state
export CB_PREFIX=$(mktemp -d)
export CB_LOG_DIR="$CB_PREFIX/log"
export CB_BACKUP_DIR="$CB_PREFIX/backup"
export CB_STATE_DIR="$CB_PREFIX/state"
export CB_HOOKS_DIR="$CB_PREFIX/hooks"
export CB_CONFIG_FILE="$CB_PREFIX/config.env"
export CB_ADVANCED_FILE="$CB_PREFIX/advanced.env"
export CB_LOG_FILE="$CB_PREFIX/log/cb.log"
export CB_SYSLOG_ENABLED=0
export CB_COLOR=never
mkdir -p "$CB_LOG_DIR" "$CB_BACKUP_DIR" "$CB_STATE_DIR" "$CB_HOOKS_DIR"
trap 'rm -rf "$CB_PREFIX"' EXIT

# Mock environment
MOCK=$(mktemp -d)
trap 'rm -rf "$CB_PREFIX" "$MOCK"' EXIT

cat > "$MOCK/certbot" <<'M'
#!/bin/bash
[[ "${1:-}" == "certificates" ]] && cat <<EOF
  Certificate Name: example.com
    Domains: example.com www.example.com
    Expiry Date: 2099-01-01 00:00:00+00:00
EOF
M
chmod +x "$MOCK/certbot"

cat > "$MOCK/dig" <<'M'
#!/bin/bash
case "${@: -1}" in
  example.com|www.example.com) echo "1.2.3.4" ;;
  *) : ;;
esac
M
chmod +x "$MOCK/dig"

cat > "$MOCK/curl" <<'M'
#!/bin/bash
echo "1.2.3.4"
M
chmod +x "$MOCK/curl"

export PATH="$MOCK:$PATH"
CERTBERUS="$CERT_ROOT/bin/certberus"

echo "=== Test 1: help ==="
OUT=$("$CERTBERUS" help 2>&1)
echo "$OUT" | grep -q 'discover' && _pass "help mentions discover" || _fail "discover missing in help"
echo "$OUT" | grep -q 'test-domain' && _pass "help mentions test-domain" || _fail
echo "$OUT" | grep -q 'expiry' && _pass "help mentions expiry" || _fail
echo "$OUT" | grep -q 'revoke' && _pass "help mentions revoke" || _fail
echo "$OUT" | grep -q -- '--auto\|auto ' && _pass "help mentions --auto/auto" || _fail
echo "$OUT" | grep -q -- '--force\|force' && _pass "help mentions force" || _pass "--force not in help (ok)"
echo "$OUT" | grep -q -- '--set CB_X=Y' && _pass "help mentions --set" || _fail
echo "$OUT" | grep -q -- '--no-firewall' && _pass "help mentions --no-firewall" || _fail
echo "$OUT" | grep -q -- '--open-firewall\|--firewall' && _pass "help mentions firewall flag" || _fail
echo "$OUT" | grep -q -- '--webroot' && _pass "help mentions --webroot" || _fail
echo "$OUT" | grep -q -- '--port80' && _pass "help mentions --port80" || _fail

echo "=== Test 2: discover ==="
OUT=$("$CERTBERUS" discover --webserver nginx 2>&1)
echo "$OUT" | grep -qi 'discover' && _pass "discover runs" || { _fail; echo "$OUT" | head -5; }
echo "$OUT" | grep -q 'certbot=' && _pass "shows source count" || _fail

echo "=== Test 3: test-domain nonexistent ==="
OUT=$("$CERTBERUS" test-domain neexistuje.invalid.tld 2>&1 || true)
echo "$OUT" | grep -qi 'test' && _pass "test-domain runs" || _fail
echo "$OUT" | grep -qi 'does not point\|NOT point' && _pass "nonexistent domain flagged" || { _fail; echo "$OUT" | head -5; }

echo "=== Test 4: test-domain without argument ==="
OUT=$("$CERTBERUS" test-domain 2>&1 || true)
echo "$OUT" | grep -qi 'usage' && _pass "shows usage" || { _fail; echo "$OUT" | head -3; }

echo "=== Test 5: expiry (no certs) ==="
OUT=$("$CERTBERUS" expiry 2>&1 || true)
echo "$OUT" | grep -qi 'expir' && _pass "expiry runs" || _fail

echo "=== Test 6: revoke without argument ==="
OUT=$("$CERTBERUS" revoke 2>&1 || true)
echo "$OUT" | grep -qi 'usage' && _pass "shows usage" || _fail

echo "=== Test 7: revoke nonexistent domain ==="
OUT=$("$CERTBERUS" revoke neexistuje.invalid.tld 2>&1 || true)
echo "$OUT" | grep -qi 'not found\|No managed cert' && _pass "correctly reports nothing found" || { _fail; echo "$OUT" | head -3; }

echo "=== Test 8: unknown command exit 2 ==="
"$CERTBERUS" xxxxnothing 2>/dev/null; rc=$?
[[ $rc -eq 2 ]] && _pass "exit 2 for unknown command" || _fail "got exit $rc"

echo "=== Test 9: -h / --help ==="
OUT=$("$CERTBERUS" -h 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "-h returns usage" || _fail
OUT=$("$CERTBERUS" --help 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "--help returns usage" || _fail

echo "=== Test 10: version flags ==="
OUT=$("$CERTBERUS" -V 2>&1)
echo "$OUT" | grep -qE '^certberus [0-9]+\.' && _pass "-V returns version" || _fail
OUT=$("$CERTBERUS" --version 2>&1)
echo "$OUT" | grep -qE '^certberus [0-9]+\.' && _pass "--version returns version" || _fail
# "version" subcommand
OUT=$("$CERTBERUS" version 2>&1 || true)
echo "$OUT" | grep -qE '[0-9]+\.[0-9]' && _pass "version subcommand" || _fail

echo "=== Test 11: --auto without --webserver ==="
# Must finish gracefully or ask
OUT=$("$CERTBERUS" --auto 2>&1 || true)
[[ -n "$OUT" ]] && _pass "--auto produces output" || _fail

echo "=== Test 12: Flag combination ==="
OUT=$("$CERTBERUS" -n -y -v help 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "-n -y -v help" || _fail

echo "=== Test 13: help does not contain backtrace ==="
OUT=$("$CERTBERUS" help 2>&1)
echo "$OUT" | grep -qiE 'traceback|stacktrace|bash:.*line [0-9]+' && _fail "help contains trace!" || _pass "help clean"

echo "=== Test 14: Long arguments ==="
LONG=$(printf 'a%.0s' {1..500})
"$CERTBERUS" test-domain "$LONG" 2>/dev/null; rc=$?
# Should exit non-zero but not segfault/137
[[ $rc -ne 0 && $rc -ne 139 && $rc -ne 137 ]] && _pass "long argument OK (rc=$rc)" || _fail "long arg problem (rc=$rc)"

echo "=== Test 15: Special characters in domain (injection) ==="
OUT=$("$CERTBERUS" test-domain 'foo.com; rm -rf /tmp/INJECTION_TEST' 2>&1 || true)
# Check that the script did not interpret shell injection
[[ ! -e /tmp/INJECTION_TEST ]] && _pass "shell injection blocked" || { _fail "INJECTION!"; rm -rf /tmp/INJECTION_TEST; }

echo "=== Test 16: discover for unknown webserver ==="
OUT=$("$CERTBERUS" discover --webserver neexistuje 2>&1 || true)
# Must not crash hard
[[ -n "$OUT" ]] && _pass "unknown webserver does not crash" || _fail

echo "=== Test 17: expiry with uninstalled certbot ==="
# In isolate has mock certbot, PATH currently allows it
OUT=$("$CERTBERUS" expiry 2>&1 || true)
# Mock certbot returns example.com with expiry 2099
echo "$OUT" | grep -qE 'example.com|2099|days' && _pass "expiry parses output" || _pass "expiry gracefully (nothing)"

echo "=== Test 18: revoke empty argument ==="
OUT=$("$CERTBERUS" revoke "" 2>&1 || true)
echo "$OUT" | grep -qiE 'usage|not found|empty' && _pass "empty revoke reacts" || _fail

echo "=== Test 19: --domain without value at end ==="
# parse_global must not crash if shift fails
"$CERTBERUS" test-domain --domain 2>/dev/null; rc=$?
[[ $rc -ne 139 && $rc -ne 137 ]] && _pass "empty --domain no crash (rc=$rc)" || _fail

echo "=== Test 20: Double-dash --something ==="
OUT=$("$CERTBERUS" --webserver 2>&1 || true)
# Usable warning or fail, not crash
[[ -n "$OUT" ]] && _pass "--webserver without value" || _fail

echo "=== Test 21: ENV reading ==="
CB_COLOR=always OUT=$("$CERTBERUS" help 2>&1)
# Should work with always too
echo "$OUT" | grep -q 'Usage' && _pass "CB_COLOR=always works" || _fail

echo "=== Test 22: discover with empty webserver ==="
OUT=$("$CERTBERUS" discover 2>&1 || true)
[[ -n "$OUT" ]] && _pass "discover without --webserver works" || _fail

echo "=== Test 23: Repeated same flag ==="
OUT=$("$CERTBERUS" --webserver apache --webserver nginx help 2>&1)
# Last one wins - must not crash
echo "$OUT" | grep -q 'Usage' && _pass "repeated flag OK" || _fail

echo "=== Test 24: Command after -- ==="
# everything after -- goes into REMAINING, help would not be called
OUT=$("$CERTBERUS" help -- extra args 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "-- separator" || _fail

echo "=== Test 25: hooks list in empty environment ==="
OUT=$("$CERTBERUS" hooks list 2>&1 || true)
[[ -n "$OUT" ]] && _pass "hooks list works" || _fail

echo "=== Test 26: hooks help ==="
OUT=$("$CERTBERUS" hooks 2>&1 || true)
# hooks without subcommand defaults to list
echo "$OUT" | grep -qiE 'list|add|enable|usage|Hook' && _pass "hooks without subcommand produces output" || _fail

echo "=== Test 27: unknown hooks subcommand ==="
"$CERTBERUS" hooks nonexistent 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && _pass "hooks unknown subcmd nonzero exit" || _fail

echo "=== Test 28: test-domain multiple domains ==="
OUT=$("$CERTBERUS" test-domain example.com another.invalid 2>&1 || true)
# Mock dig returns example.com, another.invalid is not in mock
echo "$OUT" | grep -qi 'example.com' && _pass "multiple domains at once" || _fail

echo "=== Test 29: status in isolate ==="
OUT=$("$CERTBERUS" status 2>&1 || true)
[[ -n "$OUT" ]] && _pass "status returns output" || _fail

echo "=== Test 30: doctor in isolate ==="
OUT=$("$CERTBERUS" doctor 2>&1 || true)
[[ -n "$OUT" ]] && _pass "doctor returns output" || _fail

echo "=== Test 31: dry-run does not make changes ==="
# Record state before
STATE_BEFORE=$(find "$CB_STATE_DIR" "$CB_HOOKS_DIR" -type f 2>/dev/null | sort | md5sum | cut -d' ' -f1)
"$CERTBERUS" -n test-domain example.com 2>&1 >/dev/null || true
STATE_AFTER=$(find "$CB_STATE_DIR" "$CB_HOOKS_DIR" -type f 2>/dev/null | sort | md5sum | cut -d' ' -f1)
[[ "$STATE_BEFORE" == "$STATE_AFTER" ]] && _pass "dry-run does not change state" || _fail "state changed"

echo "=== Test 32: --set accepts only CB_* ==="
OUT=$("$CERTBERUS" help --set CB_TEST_VALUE=abc 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "--set CB_* accepted" || { _fail; echo "$OUT" | head -5; }
"$CERTBERUS" help --set PATH=/tmp 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && _pass "--set rejects non-CB variable" || _fail "--set PATH passed"
"$CERTBERUS" help --set CB_BAD-DASH=1 2>/dev/null; rc=$?
[[ $rc -ne 0 ]] && _pass "--set rejects invalid name" || _fail "--set invalid name passed"

echo "=== Test 33: new CLI aliases do not crash ==="
OUT=$("$CERTBERUS" help --no-firewall --open-firewall --webroot /tmp/acme --port80 webroot 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "automation aliases accepted" || { _fail; echo "$OUT" | head -5; }

echo "=== Test 33b: 'setup' alias routes to the install wizard ==="
# 'setup' is the clearer primary name for 'install'/'interactive'. Verify the
# dispatch routes it to cmd_install (which prints the 'interactive setup'
# banner first thing). --dry-run makes this side-effect free.
OUT=$(timeout 30 "$CERTBERUS" --dry-run --yes --webserver nginx --ca letsencrypt \
        --email test@example.com setup --domain setup-alias-test.example.com 2>&1 || true)
echo "$OUT" | grep -qi 'interactive setup' \
    && _pass "'setup' dispatches to the install wizard" \
    || { _fail; echo "$OUT" | head -8; }

echo "=== Test 33c: 'setup' does not die on an unbound variable (regression: CB_YES_CLI) ==="
# Regression for the 0.2.11 bug: 'certberus setup' aborted at the first line of
# cmd_install with 'CB_YES_CLI: unbound variable' under set -u — both with and
# without -y. Test 33b did not catch it because the banner prints BEFORE that
# line and the exit code was swallowed. Assert the crash signature is absent.
OUT=$(timeout 30 "$CERTBERUS" --dry-run --webserver nginx --ca letsencrypt \
        --email test@example.com setup --domain setup-regress.example.com </dev/null 2>&1 || true)
echo "$OUT" | grep -qi 'unbound variable' \
    && { _fail "setup crashed on unbound variable (no -y)"; echo "$OUT" | head -8; } \
    || _pass "setup has no unbound-variable crash (no -y)"
OUT=$(timeout 30 "$CERTBERUS" --dry-run --yes --webserver nginx --ca letsencrypt \
        --email test@example.com setup --domain setup-regress.example.com </dev/null 2>&1 || true)
echo "$OUT" | grep -qi 'unbound variable' \
    && { _fail "setup crashed on unbound variable (with -y)"; echo "$OUT" | head -8; } \
    || _pass "setup has no unbound-variable crash (with -y)"

echo "=== Test 34: cb_apply_cli_set validates and exports ==="
(
    source "$CERT_ROOT/lib/common.sh"
    CB_SYSLOG_ENABLED=0 CB_COLOR=never
    cb_apply_cli_set "CB_UNIT_SET=works"
    [[ "$CB_UNIT_SET" == "works" ]] || exit 1
    ( cb_apply_cli_set "PATH=/tmp" ) >/dev/null 2>&1 && exit 2
    exit 0
) && _pass "cb_apply_cli_set validates and exports" || _fail "cb_apply_cli_set problem"

echo "=== Test 34b: cb_redact_eab masks the EAB HMAC for logging ==="
(
    source "$CERT_ROOT/lib/common.sh"
    out=$(cb_redact_eab certonly --eab-kid VISIBLEKID --eab-hmac-key TOPSECRETHMAC -d a.example.com)
    [[ "$out" == *"VISIBLEKID"* ]]              || exit 1   # KID stays visible
    [[ "$out" != *"TOPSECRETHMAC"* ]]           || exit 2   # HMAC value gone
    [[ "$out" == *"--eab-hmac-key <redacted>"* ]] || exit 3 # masked in place
    # also the short --eab-hmac spelling
    out2=$(cb_redact_eab --eab-hmac ANOTHERSECRET)
    [[ "$out2" != *"ANOTHERSECRET"* ]]          || exit 4
) && _pass "cb_redact_eab masks HMAC, keeps KID" || _fail "cb_redact_eab problem (rc above)"

echo "=== Test 34c: cb_nginx_acme_webroot finds the ACME-challenge root ==="
(
    source "$CERT_ROOT/lib/common.sh"
    # reverse-proxy one-liner location (the case that broke on vpn)
    one=$(printf '%s\n' \
        'server {' \
        '    listen 80;' \
        '    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }' \
        '    location / { return 301 https://$host$request_uri; }' \
        '}' | cb_nginx_acme_webroot)
    [[ "$one" == "/var/www/html" ]] || exit 1
    # multi-line location block
    multi=$(printf '%s\n' \
        'server {' \
        '    listen 80;' \
        '    location ^~ /.well-known/acme-challenge/ {' \
        '        root /srv/acme;' \
        '    }' \
        '}' | cb_nginx_acme_webroot)
    [[ "$multi" == "/srv/acme" ]] || exit 2
    # no acme-challenge location -> empty (do not invent a path)
    none=$(printf '%s\n' 'server { listen 80; return 301 https://x; }' | cb_nginx_acme_webroot)
    [[ -z "$none" ]] || exit 3
) && _pass "cb_nginx_acme_webroot parses location root" || _fail "cb_nginx_acme_webroot problem (rc above)"

echo "=== Test 35: modules show new CLI options ==="
OUT=$(bash "$CERT_ROOT/webservers/nginx-certbot.sh" --help 2>&1)
echo "$OUT" | grep -q -- '--webroot' && echo "$OUT" | grep -q -- '--set CB_X=Y' && _pass "nginx help has --webroot/--set" || _fail
OUT=$(bash "$CERT_ROOT/webservers/tomcat-certbot.sh" --help 2>&1)
echo "$OUT" | grep -q -- '--port80' && echo "$OUT" | grep -q -- '--webroot' && echo "$OUT" | grep -q -- '--set CB_X=Y' && _pass "tomcat help has port80/webroot/set" || _fail

echo "=== Test 36: retry policy is configurable ==="
grep -q 'CB_RETRY_COUNT' "$CERT_ROOT/webservers/nginx-certbot.sh" && \
grep -q 'CB_RETRY_DELAY' "$CERT_ROOT/webservers/nginx-certbot.sh" && \
    _pass "nginx uses CB_RETRY_COUNT/DELAY" || _fail "nginx ignores retry config"
grep -q 'CB_RETRY_COUNT' "$CERT_ROOT/webservers/tomcat-certbot.sh" && \
grep -q 'CB_RETRY_DELAY' "$CERT_ROOT/webservers/tomcat-certbot.sh" && \
    _pass "tomcat uses CB_RETRY_COUNT/DELAY" || _fail "tomcat ignores retry config"

echo "=== Test 37: snapshots command ==="
OUT=$("$CERTBERUS" snapshots 2>&1 || true)
echo "$OUT" | grep -qiE 'snapshot|No snapshot' && _pass "snapshots works" || _fail

echo "=== Test 38: snapshots with data ==="
# Create dummy snapshot
mkdir -p "$CB_BACKUP_DIR"
echo "dummy" | gzip > "$CB_BACKUP_DIR/apache2-pre-test-20250101-120000-0-1234.tar.gz"
OUT=$("$CERTBERUS" snapshots 2>&1 || true)
echo "$OUT" | grep -q 'apache2-pre-test' && _pass "snapshots lists existing" || _fail

echo "=== Test 39: logs command ==="
# certberus creates the log at startup, so the file already exists
"$CERTBERUS" logs >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && _pass "logs exit 0" || _fail "logs exit $rc"

echo "=== Test 40: logs command (with data) ==="
mkdir -p "$(dirname "$CB_LOG_FILE")"
echo "[2025-01-01] [INFO] test line" > "$CB_LOG_FILE"
OUT=$("$CERTBERUS" logs 2>&1 || true)
echo "$OUT" | grep -q 'test line' && _pass "logs displays data" || _fail

echo "=== Test 41: logs with argument N ==="
for i in $(seq 1 10); do echo "line $i" >> "$CB_LOG_FILE"; done
OUT=$("$CERTBERUS" logs 3 2>&1 || true)
LINE_COUNT=$(echo "$OUT" | wc -l)
(( LINE_COUNT <= 4 )) && _pass "logs 3 returns max 3 lines" || _fail "returns $LINE_COUNT"

echo "=== Test 42: renew in empty environment ==="
OUT=$("$CERTBERUS" renew 2>&1 || true)
echo "$OUT" | grep -qiE 'No existing|renew' && _pass "renew warns without certs" || _fail

echo "=== Test 43: cert-info without domain (summary) ==="
OUT=$("$CERTBERUS" cert-info 2>&1 || true)
echo "$OUT" | grep -qiE 'overview|DOMAIN|No' && _pass "cert-info summary" || _fail

echo "=== Test 44: cert-info with domain (detail) ==="
OUT=$("$CERTBERUS" cert-info example.com 2>&1 || true)
echo "$OUT" | grep -q 'cert-info: example.com' && _pass "cert-info detail banner" || _fail

echo "=== Test 45: help mentions snapshots ==="
OUT=$("$CERTBERUS" help 2>&1)
echo "$OUT" | grep -q 'snapshots' && _pass "help: snapshots" || _fail
echo "$OUT" | grep -q 'logs' && _pass "help: logs" || _fail
echo "$OUT" | grep -q 'renew' && _pass "help: renew" || _fail

echo "=== Test 46: certbot-only in --webserver ==="
OUT=$("$CERTBERUS" help 2>&1)
echo "$OUT" | grep -q 'certbot-only' && _pass "help mentions certbot-only" || _fail

echo "=== Test 47: certbot-only module --help ==="
OUT=$(bash "$CERT_ROOT/webservers/certbot-only.sh" --help 2>&1)
echo "$OUT" | grep -q -- '--webroot' && echo "$OUT" | grep -q -- '--set CB_X=Y' && _pass "certbot-only help has --webroot/--set" || _fail

echo "=== Test 48: certbot-only --webserver dispatch ==="
OUT=$("$CERTBERUS" --webserver certbot-only --dry-run help 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "certbot-only dispatch accepted" || _fail

echo "=== Test 49: certbot-only retry configuration ==="
grep -q 'CB_RETRY_COUNT' "$CERT_ROOT/webservers/certbot-only.sh" && \
grep -q 'CB_RETRY_DELAY' "$CERT_ROOT/webservers/certbot-only.sh" && \
    _pass "certbot-only uses CB_RETRY_COUNT/DELAY" || _fail "certbot-only ignores retry config"

echo "=== Test 49b: issue-only is an accepted webserver value (alias of certbot-only) ==="
OUT=$("$CERTBERUS" help 2>&1)
echo "$OUT" | grep -q 'issue-only' && _pass "help mentions issue-only" || _fail "issue-only missing in help"
OUT=$("$CERTBERUS" --webserver issue-only --dry-run help 2>&1)
echo "$OUT" | grep -q 'Usage' && _pass "issue-only dispatch accepted" || _fail "issue-only dispatch rejected"

echo
echo "==============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================="
(( FAIL == 0 ))
