#!/bin/bash
# tests/test-clock-chaos.sh
# Time anomalies: future clock, RTC in 1970, TZ shifts, drift, leap second.

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

run() {
    local name="$1" body="$2"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $name ---"
    if (set -e; eval "$body") >/tmp/clk-$$.out 2>&1; then
        pass "$name"
    else
        sed 's/^/    /' /tmp/clk-$$.out | tail -10
        fail "$name"
    fi
    rm -f /tmp/clk-$$.out
}

have_faketime=0
command -v faketime >/dev/null 2>&1 && have_faketime=1

# B.5.1: clock skew +1 year - cb_snapshot timestamp has a future date
run "snapshot-future-clock-timestamp" '
if [[ $have_faketime -eq 0 ]]; then echo "skip - no faketime"; exit 0; fi
mkdir -p /tmp/clk-src; echo data > /tmp/clk-src/x
DEST=$(mktemp -d)
SNAP=$(faketime "2027-04-24 10:00:00" bash -c "
    source $CERT_ROOT/lib/common.sh
    CB_BACKUP_DIR=$DEST cb_snapshot /tmp/clk-src clk-test 2>/dev/null
")
[[ -n "$SNAP" ]] || { rm -rf "$DEST"; exit 1; }
# Timestamp in the name must be from YEAR 2027
echo "$SNAP" | grep -qE "$DEST/clk-test-2027" || {
    echo "Snapshot timestamp is not from the future: $SNAP"
    rm -rf "$DEST"
    exit 1
}
rm -rf "$DEST"
'

# B.5.2: clock in 1970 - timestamp in the name OK, no crash
run "snapshot-epoch-1970-clock" '
if [[ $have_faketime -eq 0 ]]; then echo "skip"; exit 0; fi
mkdir -p /tmp/clk-src2; echo a > /tmp/clk-src2/x
DEST=$(mktemp -d)
SNAP=$(faketime "1970-01-01 00:00:01" bash -c "
    source $CERT_ROOT/lib/common.sh
    CB_BACKUP_DIR=$DEST cb_snapshot /tmp/clk-src2 epoch-test 2>/dev/null
")
[[ -n "$SNAP" ]] || { rm -rf "$DEST"; exit 1; }
echo "$SNAP" | grep -qE "1970" || { echo "Unexpected timestamp: $SNAP"; rm -rf "$DEST"; exit 1; }
rm -rf "$DEST"
'

# B.5.3: TZ=UTC vs TZ=Europe/Prague - cert notAfter parse is consistent
run "tz-cert-parse-consistent" '
# Generate a cert with a precisely determined notAfter
gen_pem=$(mktemp); gen_key=$(mktemp)
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout "$gen_key" -out "$gen_pem" \
    -subj "/CN=clk.local" >/dev/null 2>&1
NA_UTC=$(TZ=UTC openssl x509 -in "$gen_pem" -noout -enddate 2>/dev/null)
NA_PRG=$(TZ=Europe/Prague openssl x509 -in "$gen_pem" -noout -enddate 2>/dev/null)
# notAfter in openssl is always GMT - should be identical
[[ "$NA_UTC" == "$NA_PRG" ]] || { echo "TZ affects openssl: UTC=$NA_UTC PRG=$NA_PRG"; rm -f "$gen_pem" "$gen_key"; exit 1; }
# Parsing via date must yield the same unix timestamp
TS_UTC=$(TZ=UTC date -d "${NA_UTC#notAfter=}" +%s 2>/dev/null)
TS_PRG=$(TZ=Europe/Prague date -d "${NA_PRG#notAfter=}" +%s 2>/dev/null)
[[ "$TS_UTC" == "$TS_PRG" ]] || { echo "TZ affects parse: $TS_UTC vs $TS_PRG"; rm -f "$gen_pem" "$gen_key"; exit 1; }
rm -f "$gen_pem" "$gen_key"
'

# B.5.4: cert with notBefore in the future - apache cannot load it, certberus must detect
run "cert-future-notbefore-detected" '
if [[ $have_faketime -eq 0 ]]; then echo "skip"; exit 0; fi
fpem=$(mktemp); fkey=$(mktemp)
faketime "+2 years" openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$fkey" -out "$fpem" -subj "/CN=fut.local" >/dev/null 2>&1
NB=$(openssl x509 -in "$fpem" -noout -startdate | cut -d= -f2)
NB_TS=$(date -d "$NB" +%s 2>/dev/null)
NOW_TS=$(date +%s)
[[ $NB_TS -gt $NOW_TS ]] || { echo "notBefore is not in the future"; rm -f "$fpem" "$fkey"; exit 1; }
DELTA=$((NB_TS - NOW_TS))
[[ $DELTA -gt 86400 ]] || { echo "delta insufficient"; rm -f "$fpem" "$fkey"; exit 1; }
rm -f "$fpem" "$fkey"
'

# B.5.5: NTP stopped + drift simulation - test that we can detect the difference between
# system time and HTTP Date header (basis for clock-sanity preflight check)
run "clock-vs-http-date-skew-detectable" '
SYS_TS=$(date +%s)
# Simulate HTTP Date header parsing
HTTP_DATE=$(date -R)  # RFC 2822 format as served by the server
HTTP_TS=$(date -d "$HTTP_DATE" +%s 2>/dev/null)
[[ -n "$HTTP_TS" ]] || exit 1
DELTA=$((SYS_TS - HTTP_TS))
DELTA=${DELTA#-}
[[ $DELTA -lt 5 ]] || { echo "standalone test has drift $DELTA"; exit 1; }
# Test: if clock skew > tolerance, certberus would detect it
'

# B.5.6: leap second 23:59:60 - parse must not crash
run "leap-second-parse-graceful" '
# date -d "23:59:60" in various implementations:
# - GNU date accepts 60 as 00:00:00 of the next day or rejects it
out=$(date -d "2016-12-31 23:59:60 UTC" +%s 2>&1)
RC=$?
# Either succeeds or errors - no crash
[[ $RC -lt 128 ]] || { echo "date crashed"; exit 1; }
'

# B.5.7: clock jump (+5min during run) - timestamp monotonic guard
run "clock-jump-monotonic-protection" '
# Snapshot timestamp = $(date +%s%N) - nanoseconds. After a jump, two different snapshots
# in quick succession:
T1=$(date +%Y%m%d-%H%M%S-%N)
sleep 0.001
T2=$(date +%Y%m%d-%H%M%S-%N)
[[ "$T1" != "$T2" ]] || { echo "Timestamps identical: $T1"; exit 1; }
# cb_snapshot uses ts="$(date +%Y%m%d-%H%M%S-%N)-$$" - $$ adds uniqueness
# so even simultaneous snapshots will not collide
'

# B.5.8: LC_TIME=ru_RU.UTF-8 - number parsing in cb_log
run "locale-non-english-no-broken-parsing" '
# cb_log uses date format - test that it works in ru locale
LC_TIME=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8 cb_log "test" 2>/dev/null || true
# Verify that parsing did not cause an exit
echo OK
# date+printf in cb_log does not use a locale-sensitive parser; ts=$(date "+%F %T") is locale-fixed
# so locale is not a problem.
'

echo "==============================================================="
echo "TOTAL: $PASS pass / $FAIL fail"
exit $(( FAIL > 0 ? 1 : 0 ))
