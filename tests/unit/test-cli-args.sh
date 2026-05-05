#!/bin/bash
# tests/unit/test-cli-args.sh
# v0.1.5 regressions:
#   - 'certberus cert-info <domain>' was reading $1 instead of REMAINING[1] - banner showed
#     "(cert-info)" instead of the domain and looked in /etc/apache2/md/domains/cert-info.
#   - --firewall flag adds CB_FIREWALL_AUTO_OPEN=1; --no-firewall forces 0.
#   - build_forward_args deduplicates --domain (CLI + autodiscover was stacking duplicates).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

CB="$CB_REPO_ROOT/bin/certberus"
SANDBOX="$(t_mktempdir cli-args)" || exit 1
trap 't_cleanup' EXIT

# Test 1: --version exit 0
out=$("$CB" --version 2>&1); rc=$?
assert_exit_code "0" "$rc" "--version exit 0"
assert_match "$out" '^certberus [0-9]+\.[0-9]+\.[0-9]+' "--version format"

# Test 2: help
out=$("$CB" help 2>&1); rc=$?
assert_exit_code "0" "$rc" "help exit 0"
assert_contains "$out" "auto" "help: auto"
assert_contains "$out" "cert-info" "help: cert-info"
assert_contains "$out" "--firewall" "help: --firewall (post-v0.1.5)"

# Test 3: unknown command -> exit != 0
"$CB" wat-is-this >/dev/null 2>&1
[[ $? -ne 0 ]] && t_pass "unknown command -> exit != 0" || t_fail "unknown command passed"

# --- Library-load harness ---
# Create a scrubbed copy that does not dispatch main, only provides functions
LIB_FILE="$SANDBOX/cb_lib.sh"
awk '/^# -------- Main dispatch --------$/ {exit} {print}' "$CB" > "$LIB_FILE"

# Test 4: cmd_cert_info args - regression test
cat > "$SANDBOX/probe-cert-info.sh" <<EOF
#!/bin/bash
set -u
source "$LIB_FILE" 2>/dev/null
captured=""
cb_banner() { captured="\$*"; }
cb_log() { :; }
cb_warn(){ :; }
cb_error(){ :; }
cb_ok(){ :; }
cb_sep(){ :; }
REMAINING=("cert-info" "test.example.com")
cmd_cert_info "\${REMAINING[@]}"
echo "BANNER:\$captured"
EOF
chmod +x "$SANDBOX/probe-cert-info.sh"

out=$(bash "$SANDBOX/probe-cert-info.sh" 2>&1)
banner=$(echo "$out" | grep '^BANNER:' || true)
assert_contains "$banner" "test.example.com" "cert-info banner shows the actual domain"
assert_not_contains "$banner" "(cert-info)"     "cert-info banner does NOT show '(cert-info)' (regression)"

# Test 5: parse_global flags
cat > "$SANDBOX/probe-parse.sh" <<EOF
#!/bin/bash
set -u
source "$LIB_FILE" 2>/dev/null
cb_die(){ echo "DIE: \$*"; exit 99; }
cb_warn(){ :; }
cb_apply_cli_set() { eval "\${1%%=*}=\"\${1#*=}\""; eval "export \${1%%=*}"; }
REMAINING=()
parse_global "\$@"
echo "FW=\${CB_FIREWALL_AUTO_OPEN:-unset}"
echo "HARICA_FW=\${CB_HARICA_FIREWALL_AUTO_OPEN:-unset}"
echo "DOMAINS=\$CLI_DOMAINS"
echo "CMD=\$CB_CMD"
EOF
chmod +x "$SANDBOX/probe-parse.sh"

# A) without --firewall: default OFF (not unset, not 1)
out=$(bash "$SANDBOX/probe-parse.sh" auto --domain a.example.com 2>&1)
fw=$(echo "$out" | sed -n 's/^FW=//p')
[[ "$fw" == "unset" || "$fw" == "0" ]] && t_pass "without --firewall: FW is default (unset/0), got=$fw" \
    || t_fail "without --firewall: FW=$fw" "expected unset or 0"

# B) --firewall -> 1
out=$(bash "$SANDBOX/probe-parse.sh" auto --firewall --domain a.example.com 2>&1)
assert_contains "$out" "FW=1"        "--firewall -> CB_FIREWALL_AUTO_OPEN=1"
assert_contains "$out" "HARICA_FW=1" "--firewall -> CB_HARICA_FIREWALL_AUTO_OPEN=1"

# C) --open-firewall (legacy alias)
out=$(bash "$SANDBOX/probe-parse.sh" auto --open-firewall --domain a.example.com 2>&1)
assert_contains "$out" "FW=1" "--open-firewall (alias) -> ON"

# D) --no-firewall
out=$(bash "$SANDBOX/probe-parse.sh" auto --no-firewall --domain a.example.com 2>&1)
assert_contains "$out" "FW=0" "--no-firewall -> OFF"

# E) repeated --domain
out=$(bash "$SANDBOX/probe-parse.sh" auto --domain a.example.com --domain b.example.com 2>&1)
assert_contains "$out" "a.example.com" "domain a"
assert_contains "$out" "b.example.com" "domain b"

# Test 6: build_forward_args dedup
cat > "$SANDBOX/probe-dedup.sh" <<EOF
#!/bin/bash
set -u
source "$LIB_FILE" 2>/dev/null
cb_die(){ echo DIE; exit 99; }
cb_warn(){ :; }
CLI_DOMAINS=" foo.example.com bar.example.com foo.example.com bar.example.com "
CLI_SET_ARGS=()
build_forward_args | tr '\n' ' '
echo
EOF
chmod +x "$SANDBOX/probe-dedup.sh"
out=$(bash "$SANDBOX/probe-dedup.sh" 2>&1)
foo=$(echo "$out" | tr ' ' '\n' | grep -cx 'foo.example.com' || true)
bar=$(echo "$out" | tr ' ' '\n' | grep -cx 'bar.example.com' || true)
assert_eq "1" "$foo" "foo.example.com exactly once (dedup)"
assert_eq "1" "$bar" "bar.example.com exactly once (dedup)"

t_summary
