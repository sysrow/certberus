#!/bin/bash
# tests/test-discover.sh
# Offline tests for discover.sh + --auto with mocked certbot and DNS.
# Run:  bash tests/test-discover.sh
set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0
PASS=0

_pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
_check() {
    # Usage: _check "description" test-expression-string
    local desc="$1"; shift
    if "$@"; then _pass "$desc"; else _fail "$desc"; fi
}

# Mocks dir - must be on an exec-capable mount (/tmp is often noexec)
_pick_exec_base() {
    for b in /var/tmp "$HOME" /dev/shm /tmp; do
        [[ -d $b && -w $b ]] || continue
        local t; t=$(mktemp -d "$b/cb-mockXXXX" 2>/dev/null) || continue
        echo '#!/bin/sh' > "$t/probe"; chmod +x "$t/probe"
        if "$t/probe" >/dev/null 2>&1; then echo "$t"; return 0; fi
        rm -rf "$t"
    done
    return 1
}
MOCK=$(_pick_exec_base) || { echo "Cannot find exec-capable mount"; exit 1; }
trap 'rm -rf "$MOCK"' EXIT

# ---- Mock certbot ----
cat > "$MOCK/certbot" <<'MOCK'
#!/bin/bash
# Emulate certbot certificates output
if [[ "${1:-}" == "certificates" ]]; then
cat <<EOF
Found the following certs:
  Certificate Name: example.com
    Serial Number: deadbeef
    Key Type: ECDSA
    Domains: example.com www.example.com
    Expiry Date: 2099-01-01 00:00:00+00:00 (VALID: 1000 days)
  Certificate Name: other.test
    Domains: foo.other.test bar.other.test
    Expiry Date: 2099-01-01 00:00:00+00:00 (VALID: 1000 days)
EOF
fi
MOCK
chmod +x "$MOCK/certbot"

# ---- Mock dig for DNS ----
# Our "server IP" will be 1.2.3.4
cat > "$MOCK/dig" <<'MOCK'
#!/bin/bash
# Usage: dig +short A|AAAA|CAA domain
# Emulate: example.com, www.example.com -> 1.2.3.4 (our IP)
#          foo.other.test -> 1.2.3.4 as well
#          bar.other.test -> 9.9.9.9 (not ours)
for a in "$@"; do
    case "$a" in
        example.com|www.example.com|foo.other.test) echo "1.2.3.4"; exit 0 ;;
        bar.other.test) echo "9.9.9.9"; exit 0 ;;
        elsewhere.com) echo "8.8.8.8"; exit 0 ;;
    esac
done
exit 0
MOCK
chmod +x "$MOCK/dig"

# ---- Mock curl for cb_server_ipv4 ----
cat > "$MOCK/curl" <<'MOCK'
#!/bin/bash
# Returns our public IP
echo "1.2.3.4"
MOCK
chmod +x "$MOCK/curl"

# ---- Mock apachectl ----
cat > "$MOCK/apachectl" <<'MOCK'
#!/bin/bash
if [[ "${1:-}" == "-S" ]]; then
cat <<EOF
VirtualHost configuration:
*:443                  example.com (/etc/apache2/sites-enabled/ex.conf:1)
                       port 443 namevhost example.com
                       alias www.example.com
                       port 443 namevhost elsewhere.com
EOF
fi
MOCK
chmod +x "$MOCK/apachectl"

# ---- Mock nginx (no-op so it does not crash) ----
cat > "$MOCK/nginx" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$MOCK/nginx"

export PATH="$MOCK:$PATH"

# ---- Source libs ----
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/dns.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/discover.sh"

echo "=== Test 1: cb_discover_certbot_domains ==="
OUT=$(cb_discover_certbot_domains | sort | tr '\n' ' ')
EXP="bar.other.test example.com foo.other.test www.example.com "
if [[ "$OUT" == "$EXP" ]]; then _pass "returns all 4 domains"; else _fail "expected='$EXP' got='$OUT'"; fi

echo "=== Test 2: cb_discover_apache_domains ==="
OUT=$(cb_discover_apache_domains | sort)
# Expected: example.com, www.example.com, elsewhere.com
echo "$OUT" | grep -qFx "example.com" && _pass "contains example.com" || _fail "missing example.com"
echo "$OUT" | grep -qFx "www.example.com" && _pass "contains www.example.com" || _fail "missing alias"
echo "$OUT" | grep -qFx "elsewhere.com" && _pass "contains elsewhere.com" || _fail "missing"

echo "=== Test 2b: cb_discover_mod_md_domains (MDomain + md store) ==="
# Sandbox apache + mod_md store; fill CB_MD_TEST_ROOTS into our own dir
MD_SANDBOX="$MOCK/md-sandbox"
mkdir -p "$MD_SANDBOX/etc/apache2" "$MD_SANDBOX/store/domains/md.example.com" \
         "$MD_SANDBOX/store/staging/staging.example.com"
cat > "$MD_SANDBOX/etc/apache2/certberus-md.conf" <<EOF
MDomain configured.example.com alias.example.com
EOF
cat > "$MD_SANDBOX/store/domains/md.example.com/md.json" <<EOF
{"name":"md.example.com","domains":["md.example.com","www.md.example.com"]}
EOF
# Patch the function: redirect paths to our sandbox.
# Instead of patching we use env-overridable paths via CB_DISCOVER_APACHE_DIRS /
# CB_DISCOVER_MD_STORES, which discover.sh picks up (see below).
CB_DISCOVER_APACHE_DIRS="$MD_SANDBOX/etc/apache2" \
CB_DISCOVER_MD_STORES="$MD_SANDBOX/store" \
    OUT=$(cb_discover_mod_md_domains | sort | tr '\n' ' ')
echo "$OUT" | grep -q 'md.example.com'        && _pass "md.example.com from md.json" || _fail "expected md.example.com, got='$OUT'"
echo "$OUT" | grep -q 'staging.example.com'   && _pass "staging.example.com from dir name" || _fail "expected staging.example.com, got='$OUT'"
echo "$OUT" | grep -q 'configured.example.com' && _pass "configured.example.com from MDomain" || _fail "expected configured.example.com, got='$OUT'"

echo "=== Test 3: cb_server_ipv4 (from mock curl) ==="
CB_SERVER_IP4=""
IP=$(cb_server_ipv4)
[[ "$IP" == "1.2.3.4" ]] && _pass "returns 1.2.3.4" || _fail "got '$IP'"

echo "=== Test 4: cb_domain_points_here ==="
CB_SERVER_IP4="1.2.3.4"; CB_SERVER_IP6=""
cb_domain_points_here example.com      && _pass "example.com points here" || _fail "example.com does not point here"
cb_domain_points_here foo.other.test   && _pass "foo.other.test points here" || _fail "foo.other.test"
cb_domain_points_here bar.other.test   && _fail "bar.other.test MUST NOT point here" || _pass "bar.other.test rejected"
cb_domain_points_here elsewhere.com    && _fail "elsewhere MUST NOT" || _pass "elsewhere rejected"

echo "=== Test 5: cb_filter_points_here ==="
OUT=$(cb_filter_points_here example.com www.example.com bar.other.test elsewhere.com "*.wildcard.com")
# example.com and www.example.com allowed, others not
[[ "$OUT" == *example.com* ]] && _pass "filter passes example.com" || _fail
[[ "$OUT" == *www.example.com* ]] && _pass "filter passes www.example.com" || _fail
[[ "$OUT" != *bar.other.test* ]] && _pass "filter rejects bar.other.test" || _fail
[[ "$OUT" != *elsewhere* ]] && _pass "filter rejects elsewhere" || _fail
[[ "$OUT" != *wildcard* ]] && _pass "filter rejects wildcard" || _fail

echo "=== Test 6: cb_discover_all ==="
OUT=$(cb_discover_all apache 2>/dev/null)
cb_discover_load_stats
echo "$OUT" | grep -qFx "example.com"     && _pass "all contains example.com" || _fail
echo "$OUT" | grep -qFx "www.example.com" && _pass "all contains www" || _fail
echo "$OUT" | grep -qFx "foo.other.test"  && _pass "all contains foo.other.test (from certbot)" || _fail
echo "$OUT" | grep -qFx "bar.other.test"  && _fail "MUST NOT contain bar.other.test" || _pass "rejected"
echo "$OUT" | grep -qFx "elsewhere.com"   && _fail "MUST NOT contain elsewhere" || _pass "rejected"

# CB_DISC_SKIPPED_NO_RESOLVE must contain bar + elsewhere
[[ "${CB_DISC_SKIPPED_NO_RESOLVE:-}" == *bar.other.test* ]] && _pass "skipped records bar" || _fail "skipped: $CB_DISC_SKIPPED_NO_RESOLVE"
[[ "${CB_DISC_SKIPPED_NO_RESOLVE:-}" == *elsewhere* ]] && _pass "skipped records elsewhere" || _fail

echo "=== Test 7: auto mode without email ==="
# certberus auto without email must fail
OUT=$("$CERT_ROOT/bin/certberus" auto --webserver apache 2>&1 || true)
echo "$OUT" | grep -qi 'email' && _pass "fails with missing email" || { _fail "not caught"; echo "$OUT" | head -5; }

echo "=== Test 8: auto mode - no domains pointing here ==="
# Where DNS returns nothing for 1.2.3.4
# Use an isolated mock without matching domains
MOCK2=$(_pick_exec_base) || { echo "Cannot find exec-capable mount"; exit 1; }
cat > "$MOCK2/dig" <<'M'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *) echo "9.9.9.9"; exit 0 ;;
    esac
done
M
chmod +x "$MOCK2/dig"
cp "$MOCK/curl" "$MOCK/apachectl" "$MOCK/certbot" "$MOCK/nginx" "$MOCK2/"
OUT=$(PATH="$MOCK2:$PATH" "$CERT_ROOT/bin/certberus" auto --webserver apache --email test@example.com 2>&1 || true)
echo "$OUT" | grep -qi 'no domain found\|No valid domain' && _pass "fails when no domains found" || { _fail "not caught"; echo "$OUT" | head -5; }
rm -rf "$MOCK2"

echo
echo "==============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================="
(( FAIL == 0 ))
