#!/bin/bash
# tests/unit/test-scan.sh - cb_scan inventory smoke test.
set -uo pipefail
CB_TEST_LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"
CB_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$CB_TEST_LIB_DIR/assert.sh"
# shellcheck source=tests/lib/env.sh
source "$CB_TEST_LIB_DIR/env.sh"

t_require_tool openssl

SANDBOX="$(t_mktempdir scan)"
trap t_cleanup EXIT

# Sandbox structure: dir with cert + nginx-style config with reference
mkdir -p "$SANDBOX/etc/ssl" "$SANDBOX/etc/nginx"
CERT="$SANDBOX/etc/ssl/example.crt"
KEY="$SANDBOX/etc/ssl/example.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=test.example.com" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1 \
    || { echo "openssl gen failed - skip"; exit 77; }

cat > "$SANDBOX/etc/nginx/site.conf" <<EOF
server {
    listen 443 ssl;
    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
}
EOF

# Stubs for logger; load common and scan
t_stub_log_helpers
# common.sh only has logger functions, no runtime needed; loading scan.sh is enough.
# shellcheck source=lib/scan.sh
CB_VERBOSE=0
source "$CB_REPO_ROOT/lib/scan.sh"

# Override default paths na sandbox; CB_SCAN_ROOT pro config refs
export CB_SCAN_PATHS="$SANDBOX/etc"
export CB_SCAN_ROOT="$SANDBOX"

# ---- Test 1: TSV format finds our cert ------------------------------------
out_tsv=$(cb_scan --format tsv --no-listen 2>&1)
assert_contains "$out_tsv" "$CERT" "TSV output contains cert path"
assert_contains "$out_tsv" "test.example.com" "TSV output has CN"

# ---- Test 2: --no-fs skips FS section ------------------------------------
# (in TSV, FS rows are identified by "fs" in column 1; --no-fs skips them; path
# may still appear in config-refs)
out_nofs=$(cb_scan --format tsv --no-fs --no-config --no-listen 2>&1)
assert_not_contains "$out_nofs" "$CERT" "--no-fs+--no-config skips everything"

# ---- Test 3: config refs detect nginx ssl_certificate --------------------
out_cfg=$(cb_scan --format tsv --no-fs --no-listen 2>&1)
assert_contains "$out_cfg" "site.conf" "config-ref detects nginx site.conf"

# ---- Test 4: JSON format is valid ----------------------------------------
out_json=$(cb_scan --format json --no-listen 2>&1)
assert_contains "$out_json" "\"path\":" "JSON has path key"
# JSONL: each line is a standalone JSON object
first_line=$(echo "$out_json" | head -1)
[[ "$first_line" == "{"* && "$first_line" == *"}" ]] \
    && t_pass "JSON line has {} wrapper" \
    || t_fail "JSON line has no valid wrapper" "$first_line"

# Every line must be parseable
if command -v python3 >/dev/null 2>&1; then
    if echo "$out_json" | python3 -c '
import json,sys
for i, line in enumerate(sys.stdin):
    line = line.strip()
    if not line: continue
    json.loads(line)
' 2>/dev/null; then
        t_pass "JSONL lines parseable by python3"
    else
        t_fail "JSONL parse fail" "$(echo "$out_json" | head -5)"
    fi
fi

# ---- Test 5: unknown flag -> rc=2 -----------------------------------------
cb_scan --format bogus </dev/null >/dev/null 2>&1
rc=$?
assert_exit_code 2 "$rc" "invalid --format = rc 2"

cb_scan --bogus </dev/null >/dev/null 2>&1
rc=$?
assert_exit_code 2 "$rc" "unknown flag = rc 2"

# ---- Test 6: --help prints usage, rc=0 ---------------------------------
out_help=$(cb_scan --help 2>&1); rc=$?
assert_exit_code 0 "$rc" "--help rc 0"
assert_contains "$out_help" "format" "help mentions --format"

t_summary
