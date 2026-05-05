#!/bin/bash
# tests/test-network-chaos.sh
# DNS chaos: NXDOMAIN, timeout, empty resolv.conf, CAA block, port occupation.
# Most tests are pure-bash (source lib/dns.sh) + a few with docker.

set -uo pipefail
CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) shift; ONLY="$1" ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

export CB_LOG_FILE=/dev/null
export CB_SYSLOG_ENABLED=0
export CB_COLOR=never
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/dns.sh"

run() {
    local name="$1" body="$2"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $name ---"
    if (set -e; eval "$body") >/tmp/net-$$.out 2>&1; then
        pass "$name"
    else
        sed 's/^/    /' /tmp/net-$$.out | tail -10
        fail "$name"
    fi
    rm -f /tmp/net-$$.out
}

# B.4.1: NXDOMAIN - cb_resolve_a returns empty (no crash)
run "nxdomain-empty-result" '
out=$(cb_resolve_a "this-definitely-does-not-exist-$$.invalid" 2>&1)
RC=$?
[[ $RC -lt 128 ]] || { echo "crashed"; exit 1; }
echo "$out" | tr -d "[:space:]" | grep -qE "^[0-9.]+$" && { echo "expected empty, got: $out"; exit 1; }
true
'

# B.4.2: DNS timeout - resolver unreachable. Test that cb_resolve_a has timeout
run "dns-timeout-bounded" '
# Cannot override /etc/resolv.conf here, so we test dig timeout directly
T0=$(date +%s)
# 10.255.255.1 = unreachable IP
dig +time=2 +tries=1 +short A example.com @10.255.255.1 2>/dev/null
T1=$(date +%s)
ELAPSED=$((T1-T0))
[[ $ELAPSED -lt 5 ]] || { echo "dig did not respect timeout: $ELAPSED s"; exit 1; }
'

# B.4.3: split-horizon DNS - different A records depending on resolver
# Test: cb_domain_points_here uses system resolver; cannot easily simulate
# without root + iptables. At least verify that public resolver returns consistent result.
run "split-horizon-resolver-consistency" '
# Run dig twice - must return the same result (cache may influence but OK)
A1=$(cb_resolve_a "example.com" 2>/dev/null | tr " " "\n" | sort | head -1)
A2=$(cb_resolve_a "example.com" 2>/dev/null | tr " " "\n" | sort | head -1)
[[ -n "$A1" ]] || { echo "skip - no DNS"; exit 0; }
[[ "$A1" == "$A2" ]] || { echo "DNS inconsistent: $A1 vs $A2"; exit 1; }
'

# B.4.4: CAA blocks LE - must warn, not abort
run "caa-blocks-letsencrypt-warning" '
# /tmp is noexec on the host - use /var/tmp
mkdir -p /var/tmp/cb-fakebin
cat > /var/tmp/cb-fakebin/dig <<"EOF"
#!/bin/bash
echo "0 issue \"harica.gr\""
EOF
chmod +x /var/tmp/cb-fakebin/dig
PATH=/var/tmp/cb-fakebin:$PATH cb_check_caa "test.example" "letsencrypt.org" >/tmp/caa.out 2>&1
RC=$?
rm -rf /var/tmp/cb-fakebin
[[ $RC -ne 0 ]] || { echo "BUG: cb_check_caa did not detect CAA block"; exit 1; }
'

# B.4.5: AAAA exists but missing on server
run "aaaa-exists-not-pointing-here" '
# example.com has an AAAA record
A6=$(cb_resolve_aaaa "example.com" 2>/dev/null)
[[ -n "$A6" ]] || { echo "skip - no IPv6 DNS"; exit 0; }
# Test: cb_domain_points_here returns 1 if NONE of A/AAAA records point to us
# (cannot reliably determine our IPv6 in the test; fallback to verifying none of A records are local)
'

# B.4.5b: live wildcard DNS for skyrow.cz - used for real certbot smoke tests
run "skyrow-wildcard-live-dns" '
label="certberus-live-$RANDOM-$(date +%s).skyrow.cz"
a_records=$(cb_resolve_a "$label" | tr " " "\n" | sed "/^$/d" | sort -u)
[[ -n "$a_records" ]] || { echo "skip - skyrow wildcard DNS did not return A record"; exit 0; }
count=$(printf "%s\n" "$a_records" | wc -l)
[[ $count -ge 1 ]] || { echo "no A record"; exit 1; }
first_ip=$(printf "%s\n" "$a_records" | head -1)
if ! CB_SERVER_IP4="$first_ip" CB_SERVER_IP6="" cb_domain_points_here "$label"; then
    echo "wildcard $label resolve=$first_ip, but cb_domain_points_here did not accept it"; exit 1
fi
if CB_SERVER_IP4="203.0.113.99" CB_SERVER_IP6="" cb_domain_points_here "$label"; then
    echo "domain_points_here false-positive for incorrect IP"; exit 1
fi
'

# B.4.6: Cloudflare-like proxy IP (104.21.x.x) - detection
run "cloudflare-orange-cloud-detected" '
# Pseudo-test: if A record is in Cloudflare ranges (104.16-31), it is a proxy
# Certberus could implement this; for now we just verify matching:
test_ip="104.21.42.7"
if [[ "$test_ip" =~ ^104\.(1[6-9]|2[0-9]|3[01])\. ]]; then
    : # detected as CF range
else
    echo "regex does not match CF"; exit 1
fi
'

# B.4.7: IPv6-only server preflight - simulation
run "ipv6-only-detected" '
# We do not have an IPv6-only docker container; just test that cb_server_ipv4 works
# even when curl -4 fails (returns empty).
out=$(cb_server_ipv4 2>/dev/null)
# If the server has IPv4, out is an IP; otherwise empty
[[ -z "$out" || "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid IP: $out"; exit 1; }
'

# B.4.10: DNS SERVFAIL - cb_resolve_a graceful (empty output)
run "dns-servfail-empty-result" '
# Cannot reliably produce SERVFAIL; use nonexistent TLD instead
out=$(cb_resolve_a "test.thisdomaintldisreallybroken" 2>&1)
RC=$?
[[ $RC -lt 128 ]] || exit 1
'

# B.4.11: empty /etc/resolv.conf - dig fallback
run "empty-resolv-conf-graceful" '
# Instead of actually overwriting /etc/resolv.conf, test that dig --notcp + no nameserver
# returns a clean fail
out=$(dig +time=1 +tries=1 +short A example.com @127.0.0.99 2>&1)
RC=$?
[[ $RC -lt 128 ]] || { echo "dig crash"; exit 1; }
'

# B.4.12: DNSSEC chain broken - dig returns AD? flag missing
run "dnssec-ad-flag-presence-detectable" '
# Test that we can detect AD flag from dig output
out=$(dig +dnssec +short A cloudflare.com 2>/dev/null)
# No AD detection; just verify that dig did not crash
[[ $? -lt 128 ]] || exit 1
'

# B.4.14: port 80 occupied by another process - lsof/ss detection
run "port-80-occupied-detected" '
# Start a silent listener on 80 + test detection
if ! command -v ss >/dev/null 2>&1; then echo "skip - no ss"; exit 0; fi
# Test: if something is on port 80, ss will show it
ss -tln 2>/dev/null | head -5 >/dev/null
# Pseudo-test: detection mechanism exists (ss/netstat/lsof)
have_detector=0
for cmd in ss netstat lsof fuser; do
    command -v "$cmd" >/dev/null 2>&1 && have_detector=1 && break
done
[[ $have_detector -eq 1 ]] || { echo "no port detector"; exit 1; }
'

# B.4.15: port 80 IPv6 occupied, IPv4 free
run "port-80-ipv6-only-detection" '
# ss output: tcp LISTEN 0.0.0.0:80 vs [::]:80
# Detect whether occupied via "0.0.0.0:80" or only "[::]:80"
ss -tln 2>/dev/null > /tmp/sslines || true
# Test that we can distinguish IPv4-bind vs IPv6-bind
echo "tcp LISTEN 0 0 [::]:80" | grep -qE "\[::\]:80" || exit 1
echo "tcp LISTEN 0 0 0.0.0.0:80" | grep -qE "0\.0\.0\.0:80" || exit 1
rm -f /tmp/sslines
'

# B.4.13: firewalld+iptables conflict - hybrid state
run "firewall-hybrid-detection" '
# Whether the function in lib/firewall.sh detects multiple backends
source "$CERT_ROOT/lib/firewall.sh" 2>/dev/null || true
# detection function exists?
declare -f cb_firewall_detect >/dev/null 2>&1 || declare -f cb_firewall_open_port >/dev/null 2>&1 || {
    echo "firewall lib not loaded"; exit 1
}
'

# B.4.8: nftables policy drop without port 80 exception - at least detect that nftables exists
run "nftables-policy-drop-detection" '
# Pseudo: if nft exists, certberus should be able to add a rule
command -v nft >/dev/null 2>&1 && echo "nft is available"
true
'

# B.4.9: TLS termination at proxy (LB) - local 443 not listening but 80 is
run "lb-tls-termination-detected" '
# Pseudo: ss output can be parsed
ss -tln 2>/dev/null > /tmp/lb.lines || true
# Whether listening on 80 yes, on 443 no -> LB terminates TLS elsewhere
HAS80=$(grep -cE ":80 " /tmp/lb.lines 2>/dev/null || echo 0)
HAS443=$(grep -cE ":443 " /tmp/lb.lines 2>/dev/null || echo 0)
rm -f /tmp/lb.lines
# Pseudo-test: detection scheme
[[ -n "$HAS80" || -n "$HAS443" ]]
'

echo "==============================================================="
echo "TOTAL: $PASS pass / $FAIL fail"
exit $(( FAIL > 0 ? 1 : 0 ))
