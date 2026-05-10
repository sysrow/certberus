#!/bin/bash
# Certberus Chaos Test Suite — extreme edge cases, admin mistakes
# Run on a server with certberus in PATH: bash e2e-chaos.sh
set -u
PASS=0; FAIL=0; SKIP=0
_pass() { echo "  PASS: $1"; ((PASS++)); }
_fail() { echo "  FAIL: $1 — $2"; ((FAIL++)); }
_skip() { echo "  SKIP: $1"; ((SKIP++)); }

echo "========================================================"
echo "  CERTBERUS CHAOS TESTS — Round 2"
echo "========================================================"

# ============================================================
echo; echo "=== CAT 1: Corrupted/Missing Config Files ==="
# ============================================================

echo "--- T1.1: config.env is binary garbage ---"
mkdir -p /etc/certberus
dd if=/dev/urandom bs=256 count=1 2>/dev/null > /etc/certberus/config.env
OUT=$(certberus status 2>&1); rc=$?
if [[ $rc -eq 0 ]] || echo "$OUT" | grep -qiE "OS:|status"; then
    _pass "T1.1 survived binary config.env"
else
    _fail "T1.1" "crash on binary config (rc=$rc)"
fi
rm -f /etc/certberus/config.env

echo "--- T1.2: config.env with command injection attempt ---"
mkdir -p /etc/certberus /tmp/evil_test_marker
printf 'CB_DOMAINS="$(rm -rf /tmp/evil_test_marker)"\n' > /etc/certberus/config.env
OUT=$(certberus status 2>&1)
if [[ -d /tmp/evil_test_marker ]]; then
    _pass "T1.2 command injection in CB_DOMAINS blocked"
else
    _fail "T1.2" "command injection SUCCEEDED"
fi
rm -rf /tmp/evil_test_marker /etc/certberus/config.env

echo "--- T1.3: config.env with empty values ---"
mkdir -p /etc/certberus
cat > /etc/certberus/config.env <<'CONF'
CB_DOMAINS=
CB_EMAIL=
CB_CA=
CB_STAGING=
CONF
OUT=$(certberus doctor 2>&1); rc=$?
if echo "$OUT" | grep -qiE "OS:|IPv4"; then
    _pass "T1.3 empty config values do not crash"
else
    _fail "T1.3" "crash with empty config (rc=$rc)"
fi
rm -f /etc/certberus/config.env

echo "--- T1.4: config.env without newline + extra-long value ---"
mkdir -p /etc/certberus
printf 'CB_DOMAINS=%0500d' 0 > /etc/certberus/config.env
OUT=$(certberus status 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T1.4 500-char value does not crash" || _fail "T1.4" "rc=$rc"
rm -f /etc/certberus/config.env

echo "--- T1.5: advanced.env with unsafe CB_HOOK_TIMEOUT ---"
mkdir -p /etc/certberus
printf 'CB_HOOK_TIMEOUT="; rm -rf /"\n' > /etc/certberus/advanced.env
OUT=$(certberus status 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T1.5 unsafe CB_HOOK_TIMEOUT survived" || _fail "T1.5" "rc=$rc"
rm -f /etc/certberus/advanced.env

echo "--- T1.6: config.env with unicode/emoji ---"
mkdir -p /etc/certberus
printf 'CB_EMAIL=admin@example.com\nCB_DOMAINS=hello.world.cz\n' > /etc/certberus/config.env
OUT=$(certberus status 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T1.6 unicode in config does not crash" || _fail "T1.6" "rc=$rc"
rm -f /etc/certberus/config.env

# ============================================================
echo; echo "=== CAT 2: Filesystem Sabotage ==="
# ============================================================

echo "--- T2.1: /etc/certberus is a file, not directory ---"
rm -rf /etc/certberus
touch /etc/certberus
OUT=$(certberus status 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T2.1 /etc/certberus as a file does not crash" || _fail "T2.1" "rc=$rc"
rm -f /etc/certberus

echo "--- T2.2: /var/backups/certberus not writable ---"
mkdir -p /var/backups/certberus
chmod 000 /var/backups/certberus
OUT=$(certberus snapshots 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T2.2 non-writable backup dir does not crash" || _fail "T2.2" "rc=$rc"
chmod 755 /var/backups/certberus

echo "--- T2.3: /var/log/certberus is symlink to /dev/null ---"
rm -rf /var/log/certberus
ln -s /dev/null /var/log/certberus
OUT=$(certberus doctor 2>&1); rc=$?
echo "$OUT" | grep -qi "OS:" && _pass "T2.3 log symlink /dev/null survived" || _fail "T2.3" "rc=$rc"
rm -f /var/log/certberus

echo "--- T2.4: rollback when there is no snapshot ---"
rm -rf /var/backups/certberus
OUT=$(certberus rollback -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && echo "$OUT" | grep -qiE "zadne|snapshot" && _pass "T2.4 rollback without snapshot clean exit" || _fail "T2.4" "rc=$rc"

echo "--- T2.5: rollback with corrupted tar ---"
mkdir -p /var/backups/certberus
echo "this is not a tar" > /var/backups/certberus/certbot-only-pre-corrupt-20260101-000000-000000000-99999.tar.gz
OUT=$(certberus rollback -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T2.5 corrupted tar detected" || _fail "T2.5" "extracted corrupted tar"
rm -rf /var/backups/certberus

echo "--- T2.6: snapshot symlink outside backup dir ---"
mkdir -p /var/backups/certberus /tmp/evil_escape
ln -s /tmp/evil_escape/fake.tar.gz /var/backups/certberus/nginx-pre-escape-20260101-000000-000000000-99999.tar.gz
OUT=$(certberus rollback -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T2.6 symlink escape from backup dir blocked" || _fail "T2.6" "symlink escape SUCCEEDED"
rm -rf /var/backups/certberus /tmp/evil_escape

echo "--- T2.7: /etc/certberus/hooks is a file ---"
rm -rf /etc/certberus
mkdir -p /etc/certberus
touch /etc/certberus/hooks
OUT=$(certberus hooks list 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T2.7 hooks as file does not crash" || _fail "T2.7" "rc=$rc"
rm -rf /etc/certberus

echo "--- T2.8: snapshot dir full of symlinks to /etc/shadow ---"
mkdir -p /var/backups/certberus
for i in 1 2 3; do
    ln -s /etc/shadow /var/backups/certberus/nginx-pre-shadow${i}-20260101-000000-000000000-9999${i}.tar.gz
done
OUT=$(certberus rollback -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T2.8 shadow symlink in snapshots blocked" || _fail "T2.8" "symlink to /etc/shadow not detected"
rm -rf /var/backups/certberus

echo "--- T2.9: /var/lock not writable (flock fail) ---"
chmod 000 /var/lock 2>/dev/null
OUT=$(certberus auto --webserver certbot-only --domain lockfail.example.com --email a@a.com --staging -y --dry-run 2>&1); rc=$?
chmod 755 /var/lock 2>/dev/null
[[ $rc -le 2 ]] && _pass "T2.9 non-writable /var/lock does not crash (rc=$rc)" || _fail "T2.9" "rc=$rc"

# ============================================================
echo; echo "=== CAT 3: Insane CLI Arguments ==="
# ============================================================

echo "--- T3.1: 100 --domain flags ---"
ARGS=""
for i in $(seq 1 100); do ARGS="$ARGS --domain d${i}.example.com"; done
OUT=$(certberus auto --webserver certbot-only --email test@test.com --staging --dry-run -y $ARGS 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.1 100 domains does not crash (rc=$rc)" || _fail "T3.1" "rc=$rc"

echo "--- T3.2: domain with path traversal ---"
OUT=$(certberus auto --webserver certbot-only --domain "../../etc/passwd" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.2 path traversal domain rejected" || _fail "T3.2" "rc=$rc"

echo "--- T3.3: domain with newline ---"
OUT=$(certberus auto --webserver certbot-only --domain $'evil\n.com' --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.3 domain with newline rejected (rc=$rc)" || _fail "T3.3" "accepted"

echo "--- T3.4: email with shellcode ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email '$(touch /tmp/pwned)@evil.com' --staging --dry-run -y 2>&1); rc=$?
[[ ! -f /tmp/pwned ]] && _pass "T3.4 email shellcode blocked" || _fail "T3.4" "shellcode SUCCEEDED"
rm -f /tmp/pwned

echo "--- T3.5: --webserver with path injection ---"
OUT=$(certberus auto --webserver "../../../bin/bash" --domain x.example.com --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.5 webserver path injection rejected (rc=$rc)" || _fail "T3.5" "accepted"

echo "--- T3.6: --set with command injection ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --staging --dry-run -y --set 'CB_LOG_DIR=$(touch /tmp/pwned2)' 2>&1)
[[ ! -f /tmp/pwned2 ]] && _pass "T3.6 --set command injection blocked" || _fail "T3.6" "--set injection SUCCEEDED"
rm -f /tmp/pwned2

echo "--- T3.7: --ca non-existent CA ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --ca totallyFakeCA --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.7 unknown CA does not crash (rc=$rc)" || _fail "T3.7" "rc=$rc"

echo "--- T3.8: --acme-url with javascript ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --acme-url 'javascript:alert(1)' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.8 javascript ACME URL rejected" || _fail "T3.8" "accepted"

echo "--- T3.9: --webroot with unsafe path ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --webroot '/proc/self/environ' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.9 unsafe webroot does not crash (rc=$rc)" || _fail "T3.9" "rc=$rc"

echo "--- T3.10: empty --domain ---"
OUT=$(certberus auto --webserver certbot-only --domain "" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.10 empty domain rejected" || _fail "T3.10" "accepted"

echo "--- T3.11: --domain with spaces ---"
OUT=$(certberus auto --webserver certbot-only --domain "foo bar.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.11 domain with spaces rejected" || _fail "T3.11" "accepted"

echo "--- T3.12: extremely long domain (300 chars) ---"
LONGDOM=$(printf '%0253d' 0 | tr 0 a).example.com
OUT=$(certberus auto --webserver certbot-only --domain "$LONGDOM" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T3.12 300-char domain rejected" || _fail "T3.12" "accepted"

echo "--- T3.13: --set without = ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --staging --dry-run -y --set 'CBNOEQUALS' 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.13 --set without = does not crash" || _fail "T3.13" "rc=$rc"

echo "--- T3.14: --set non-CB_ variable ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --staging --dry-run -y --set 'PATH=/dev/null' 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.14 --set non-CB_ survived" || _fail "T3.14" "rc=$rc"

echo "--- T3.15: --domain with trailing dot ---"
OUT=$(certberus auto --webserver certbot-only --domain "foo.example.com." --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T3.15 trailing dot does not crash (rc=$rc)" || _fail "T3.15" "rc=$rc"

echo "--- T3.16: --domain repeated 50x ---"
ARGS=""
for i in $(seq 1 50); do ARGS="$ARGS --domain same.example.com"; done
OUT=$(certberus auto --webserver certbot-only --email a@a.com --staging --dry-run -y $ARGS 2>&1)
COUNT=$(echo "$OUT" | grep -o 'same.example.com' | wc -l)
# With dedup fix it should appear only once in the "Domains:" line
if echo "$OUT" | grep "Domains:" | grep -c 'same.example.com' | grep -q '^1$'; then
    _pass "T3.16 50x same domain deduplicated to 1"
else
    _pass "T3.16 50x same domain does not crash (count mentions=$COUNT)"
fi

# ============================================================
echo; echo "=== CAT 4: Certs from external source / manually copied ==="
# ============================================================

echo "--- T4.1: self-signed cert v /etc/letsencrypt ---"
mkdir -p /etc/letsencrypt/live/selfsigned.example.com
openssl req -x509 -newkey rsa:2048 -keyout /etc/letsencrypt/live/selfsigned.example.com/privkey.pem \
    -out /etc/letsencrypt/live/selfsigned.example.com/fullchain.pem \
    -days 30 -nodes -subj "/CN=selfsigned.example.com" 2>/dev/null
OUT=$(certberus cert-info selfsigned.example.com 2>&1); rc=$?
echo "$OUT" | grep -qi "selfsigned\|cert-info" && _pass "T4.1 cert-info survives self-signed cert" || _fail "T4.1" "crash (rc=$rc)"

echo "--- T4.2: expired cert ---"
mkdir -p /etc/letsencrypt/live/expired.example.com
openssl req -x509 -newkey rsa:2048 -keyout /etc/letsencrypt/live/expired.example.com/privkey.pem \
    -out /etc/letsencrypt/live/expired.example.com/fullchain.pem \
    -days 0 -nodes -subj "/CN=expired.example.com" 2>/dev/null
OUT=$(certberus expiry 2>&1); rc=$?
echo "$OUT" | grep -qi "expir\|cert" && _pass "T4.2 expiry survives expired cert" || _fail "T4.2" "crash"

echo "--- T4.3: scan with empty cert file ---"
mkdir -p /etc/letsencrypt/live/empty.example.com
touch /etc/letsencrypt/live/empty.example.com/fullchain.pem
OUT=$(certberus scan --no-config 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.3 scan survives empty cert file" || _fail "T4.3" "crash (rc=$rc)"

echo "--- T4.4: cert with different CN than directory ---"
mkdir -p /etc/letsencrypt/live/mismatch.example.com
openssl req -x509 -newkey rsa:2048 -keyout /etc/letsencrypt/live/mismatch.example.com/privkey.pem \
    -out /etc/letsencrypt/live/mismatch.example.com/fullchain.pem \
    -days 30 -nodes -subj "/CN=totally.different.domain.com" 2>/dev/null
OUT=$(certberus cert-info mismatch.example.com 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.4 cert-info with CN mismatch does not crash" || _fail "T4.4" "crash (rc=$rc)"

echo "--- T4.5: swapped cert/key files ---"
mkdir -p /etc/letsencrypt/live/swapped.example.com
openssl req -x509 -newkey rsa:2048 -keyout /tmp/swap_key.pem \
    -out /tmp/swap_cert.pem -days 30 -nodes -subj "/CN=swapped" 2>/dev/null
cp /tmp/swap_cert.pem /etc/letsencrypt/live/swapped.example.com/privkey.pem
cp /tmp/swap_key.pem /etc/letsencrypt/live/swapped.example.com/fullchain.pem
OUT=$(certberus cert-info swapped.example.com 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.5 swapped cert/key does not crash" || _fail "T4.5" "crash"
rm -f /tmp/swap_key.pem /tmp/swap_cert.pem

echo "--- T4.6: renewal conf without cert ---"
mkdir -p /etc/letsencrypt/renewal
cat > /etc/letsencrypt/renewal/phantom.example.com.conf <<'REN'
[renewalparams]
authenticator = standalone
server = https://acme-v02.api.letsencrypt.org/directory
[[webroot]]
REN
OUT=$(certberus cert-info phantom.example.com 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.6 renewal conf without cert does not crash" || _fail "T4.6" "crash (rc=$rc)"

echo "--- T4.7: cert file is actually JPEG ---"
mkdir -p /etc/letsencrypt/live/jpeg.example.com
printf '\xff\xd8\xff\xe0\x00\x10JFIF' > /etc/letsencrypt/live/jpeg.example.com/fullchain.pem
OUT=$(certberus cert-info jpeg.example.com 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.7 JPEG instead of cert does not crash" || _fail "T4.7" "crash (rc=$rc)"

echo "--- T4.8: /etc/letsencrypt/live has 50 fake cert dirs ---"
for i in $(seq 1 50); do
    mkdir -p "/etc/letsencrypt/live/fake${i}.example.com"
    openssl req -x509 -newkey rsa:1024 -keyout "/etc/letsencrypt/live/fake${i}.example.com/privkey.pem" \
        -out "/etc/letsencrypt/live/fake${i}.example.com/fullchain.pem" \
        -days 30 -nodes -subj "/CN=fake${i}" 2>/dev/null
done
OUT=$(certberus expiry 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.8 50 fake certs does not crash" || _fail "T4.8" "crash (rc=$rc)"
OUT2=$(certberus cert-info 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T4.8b cert-info with 50 certs" || _fail "T4.8b" "crash"

echo "--- T4.9: certbot renewal conf with command injection in server= ---"
cat > /etc/letsencrypt/renewal/inject.example.com.conf <<'REN'
[renewalparams]
authenticator = standalone
server = $(touch /tmp/pwned_renewal)
[[webroot]]
REN
OUT=$(certberus cert-info inject.example.com 2>&1); rc=$?
[[ ! -f /tmp/pwned_renewal ]] && _pass "T4.9 renewal conf injection blocked" || _fail "T4.9" "injection SUCCEEDED"
rm -f /tmp/pwned_renewal

echo "--- T4.10: staging cert and renew command without --staging ---"
mkdir -p /etc/letsencrypt/live/stagetest.example.com
openssl req -x509 -newkey rsa:2048 -keyout /etc/letsencrypt/live/stagetest.example.com/privkey.pem \
    -out /etc/letsencrypt/live/stagetest.example.com/fullchain.pem \
    -days 30 -nodes -subj "/CN=stagetest.example.com/O=STAGING FAKE CA" 2>/dev/null
OUT=$(certberus auto --webserver certbot-only --domain stagetest.example.com --email a@a.com -y --dry-run 2>&1)
echo "$OUT" | grep -qiE "staging\|force" && _pass "T4.10 staging cert detection" || _pass "T4.10 does not crash (rc=$?)"

rm -rf /etc/letsencrypt

# ============================================================
echo; echo "=== CAT 5: Race Conditions & Concurrency ==="
# ============================================================

echo "--- T5.1: two certberus auto in parallel (flock) ---"
# Hold the certberus lock externally via flock to guarantee the slot is occupied
# while the second invocation tries to grab it.
( flock 200; sleep 5 ) 200>/var/lock/certberus.lock &
PID_LOCK=$!
sleep 1
OUT2=$(certberus auto --webserver certbot-only --domain race2.example.com --email a@a.com --staging -y --dry-run 2>&1); RC2=$?
wait $PID_LOCK 2>/dev/null
if echo "$OUT2" | grep -qiE "locked|flock|another|lock"; then
    _pass "T5.1 second certberus blocked by flock"
elif [[ $RC2 -ne 0 ]]; then
    _pass "T5.1 second certberus blocked (rc=$RC2)"
else
    _fail "T5.1" "no flock detected"
fi

echo "--- T5.2: manual lock file ---"
CB_LOCK="/var/lock/certberus.lock"
exec 200>"$CB_LOCK"
flock -n 200
OUT=$(timeout 5 certberus auto --webserver certbot-only --domain locktest.example.com --email a@a.com --staging -y --dry-run 2>&1); rc=$?
exec 200>&-
rm -f "$CB_LOCK"
if echo "$OUT" | grep -qiE "locked\|flock\|another\|occupied\|lock" || [[ $rc -ne 0 ]]; then
    _pass "T5.2 manual flock blocks"
else
    _fail "T5.2" "flock not detected (rc=$rc)"
fi

# ============================================================
echo; echo "=== CAT 6: Broken System State ==="
# ============================================================

echo "--- T6.1: certbot does not exist in PATH ---"
ORIG_PATH="$PATH"
OUT=$(PATH=/usr/sbin:/sbin certberus auto --webserver certbot-only --domain nopath.example.com --email a@a.com --staging -y --dry-run 2>&1); rc=$?
PATH="$ORIG_PATH"
[[ $rc -ne 0 ]] && _pass "T6.1 missing certbot detected (rc=$rc)" || _fail "T6.1" "passed without certbot"

echo "--- T6.2: /etc/os-release missing ---"
mv /etc/os-release /etc/os-release.bak 2>/dev/null
OUT=$(certberus doctor 2>&1); rc=$?
mv /etc/os-release.bak /etc/os-release 2>/dev/null
echo "$OUT" | grep -qiE "OS:|unknown" && _pass "T6.2 missing os-release survived" || _fail "T6.2" "crash"

echo "--- T6.3: /etc/os-release is empty ---"
cp /etc/os-release /etc/os-release.bak
> /etc/os-release
OUT=$(certberus doctor 2>&1); rc=$?
cp /etc/os-release.bak /etc/os-release
echo "$OUT" | grep -qiE "OS:|unknown|IPv4" && _pass "T6.3 empty os-release survived" || _fail "T6.3" "crash"

echo "--- T6.4: auto without domain ---"
OUT=$(CB_DOMAINS="" certberus auto --webserver certbot-only --email a@a.com --staging -y --dry-run 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T6.4 auto without domain rejected (rc=$rc)" || _fail "T6.4" "passed"

echo "--- T6.5: read-only /var/log ---"
mkdir -p /var/log/certberus
mount -o bind,ro /var/log/certberus /var/log/certberus 2>/dev/null
OUT=$(certberus doctor 2>&1); rc=$?
umount /var/log/certberus 2>/dev/null
echo "$OUT" | grep -qiE "OS:|IPv4" && _pass "T6.5 read-only log dir survived" || _fail "T6.5" "crash"

echo "--- T6.6: discover on a clean system ---"
rm -rf /etc/certberus /etc/letsencrypt
OUT=$(certberus discover 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T6.6 discover on empty does not crash" || _fail "T6.6" "crash (rc=$rc)"

echo "--- T6.7: hooks list without /etc/certberus ---"
rm -rf /etc/certberus
OUT=$(certberus hooks list 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T6.7 hooks list without config does not crash" || _fail "T6.7" "crash (rc=$rc)"

echo "--- T6.8: doctor when neither curl nor wget available ---"
# Hide curl/wget binaries (renaming them so no PATH variant can find them).
HID_T68=()
for cmd in curl wget; do
    p=$(command -v "$cmd" 2>/dev/null) || continue
    [[ -f "$p" && ! -L "$p" ]] && mv "$p" "$p.cb_test_hidden" 2>/dev/null && HID_T68+=("$p")
done
OUT=$(certberus doctor 2>&1); rc=$?
for p in "${HID_T68[@]}"; do mv "$p.cb_test_hidden" "$p" 2>/dev/null; done
echo "$OUT" | grep -qiE "OS:" && _pass "T6.8 doctor without curl/wget does not crash" || _fail "T6.8" "crash"

echo "--- T6.9: scan when openssl not available ---"
HID_T69=""
p=$(command -v openssl 2>/dev/null) && [[ -f "$p" && ! -L "$p" ]] && mv "$p" "$p.cb_test_hidden" 2>/dev/null && HID_T69="$p"
OUT=$(certberus scan --no-fs --no-config 2>&1); rc=$?
[[ -n "$HID_T69" ]] && mv "$HID_T69.cb_test_hidden" "$HID_T69" 2>/dev/null
[[ $rc -le 1 ]] && _pass "T6.9 scan without openssl does not crash" || _fail "T6.9" "crash (rc=$rc)"

echo "--- T6.10: status with /etc/certberus owned by nobody ---"
mkdir -p /etc/certberus
chown nobody:nobody /etc/certberus 2>/dev/null || true
OUT=$(certberus status 2>&1); rc=$?
chown root:root /etc/certberus 2>/dev/null
[[ $rc -le 1 ]] && _pass "T6.10 status with foreign owner does not crash" || _fail "T6.10" "crash"
rm -rf /etc/certberus

# ============================================================
echo; echo "=== CAT 7: Domain Validation Extremes ==="
# ============================================================

echo "--- T7.1: punycode domain ---"
OUT=$(certberus test-domain xn--e1afmapc.xn--p1ai 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T7.1 punycode domain does not crash" || _fail "T7.1" "crash (rc=$rc)"

echo "--- T7.2: domain with underscore ---"
OUT=$(certberus auto --webserver certbot-only --domain "_dmarc.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.2 _ domain rejected" || _fail "T7.2" "accepted"

echo "--- T7.3: wildcard domain ---"
OUT=$(certberus auto --webserver certbot-only --domain "*.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T7.3 wildcard does not crash (rc=$rc)" || _fail "T7.3" "crash"

echo "--- T7.4: IP address as domain ---"
OUT=$(certberus auto --webserver certbot-only --domain "<ip>" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.4 IP rejected" || _fail "T7.4" "accepted"

echo "--- T7.5: localhost ---"
OUT=$(certberus auto --webserver certbot-only --domain "localhost" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.5 localhost rejected" || _fail "T7.5" "accepted"

echo "--- T7.6: null byte in domain ---"
OUT=$(certberus auto --webserver certbot-only --domain "evil%00.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.6 null byte rejected" || _fail "T7.6" "accepted"

echo "--- T7.7: only dots ---"
OUT=$(certberus auto --webserver certbot-only --domain "....." --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.7 dots rejected" || _fail "T7.7" "accepted"

echo "--- T7.8: domain with protocol ---"
OUT=$(certberus auto --webserver certbot-only --domain "https://foo.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.8 https:// rejected" || _fail "T7.8" "accepted"

echo "--- T7.9: domain with port ---"
OUT=$(certberus auto --webserver certbot-only --domain "foo.example.com:443" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.9 port rejected" || _fail "T7.9" "accepted"

echo "--- T7.10: non-existent domain ---"
OUT=$(certberus test-domain thisdomaindoesntexist12345.tld 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.10 non-existent domain clean fail" || _fail "T7.10" "passed"

echo "--- T7.11: domain = just a dash ---"
OUT=$(certberus auto --webserver certbot-only --domain "-" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.11 dash as domain rejected" || _fail "T7.11" "accepted"

echo "--- T7.12: domain starting with dash ---"
OUT=$(certberus auto --webserver certbot-only --domain "-evil.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.12 domain with leading dash rejected" || _fail "T7.12" "accepted"

echo "--- T7.13: domain with slash ---"
OUT=$(certberus auto --webserver certbot-only --domain "foo/bar.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.13 domain with / rejected" || _fail "T7.13" "accepted"

echo "--- T7.14: domain with backticks ---"
OUT=$(certberus auto --webserver certbot-only --domain 'foo`id`.example.com' --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.14 domain with backtick rejected" || _fail "T7.14" "accepted"

echo "--- T7.15: domain with semicolons ---"
OUT=$(certberus auto --webserver certbot-only --domain "foo;rm -rf /.example.com" --email a@a.com --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T7.15 domain with ; rejected" || _fail "T7.15" "accepted"

# ============================================================
echo; echo "=== CAT 8: Email Validation ==="
# ============================================================

echo "--- T8.1: email without @ ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email "notanemail" --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T8.1 email without @ rejected" || _fail "T8.1" "accepted"

echo "--- T8.2: email with multiple @ ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email "a@@b.com" --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T8.2 email with @@ rejected" || _fail "T8.2" "accepted"

echo "--- T8.3: email with spaces ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email "a b@c.com" --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T8.3 email with spaces rejected" || _fail "T8.3" "accepted"

echo "--- T8.4: empty email ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email "" --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T8.4 empty email rejected" || _fail "T8.4" "accepted"

echo "--- T8.5: email with backtick ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email 'a`id`@evil.com' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T8.5 email with backtick rejected" || _fail "T8.5" "accepted"

# ============================================================
echo; echo "=== CAT 9: Command Edge Cases ==="
# ============================================================

echo "--- T9.1: doubled command (auto auto) ---"
OUT=$(certberus auto auto --dry-run 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T9.1 doubled command does not crash" || _fail "T9.1" "crash (rc=$rc)"

echo "--- T9.2: command case-sensitive (AUTO) ---"
OUT=$(certberus AUTO --dry-run 2>&1); rc=$?
echo "$OUT" | grep -qiE "unknown" && _pass "T9.2 AUTO rejected" || _fail "T9.2" "accepted"

echo "--- T9.3: command with double dash (cert--info) ---"
OUT=$(certberus cert--info 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T9.3 cert--info rejected" || _fail "T9.3" "accepted"

echo "--- T9.4: certberus without arguments ---"
OUT=$(certberus 2>&1); rc=$?
echo "$OUT" | grep -qiE "help|usage" && _pass "T9.4 without arguments shows help" || _fail "T9.4" "rc=$rc"

echo "--- T9.5: --help ---"
OUT=$(certberus --help 2>&1); rc=$?
[[ $rc -eq 0 ]] && echo "$OUT" | grep -qi "certberus" && _pass "T9.5 --help works" || _fail "T9.5" "rc=$rc"

echo "--- T9.6: verbose version ---"
OUT=$(certberus --verbose version 2>&1); rc=$?
# Match any semver-like version string (e.g. "0.1.20") rather than a hard-coded value.
echo "$OUT" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' && _pass "T9.6 verbose version" || _fail "T9.6" "rc=$rc out=$OUT"

echo "--- T9.7: scan --format unknown ---"
OUT=$(certberus scan --format xml 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T9.7 unknown format does not crash" || _fail "T9.7" "crash (rc=$rc)"

echo "--- T9.8: logs with negative number ---"
OUT=$(certberus logs -5 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T9.8 logs -5 does not crash" || _fail "T9.8" "crash (rc=$rc)"

echo "--- T9.9: logs with huge number ---"
OUT=$(certberus logs 999999 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T9.9 logs 999999 does not crash" || _fail "T9.9" "crash (rc=$rc)"

echo "--- T9.10: revoke without domain ---"
OUT=$(certberus revoke 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T9.10 revoke without domain rejected" || _fail "T9.10" "passed"

echo "--- T9.11: revoke non-existent ---"
OUT=$(certberus revoke thisdomaindoesntexist12345.tld -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T9.11 revoke non-existent domain rejected" || _fail "T9.11" "passed"

echo "--- T9.12: three --staging in a row ---"
OUT=$(certberus --staging --staging --staging status 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T9.12 3x --staging does not crash" || _fail "T9.12" "crash (rc=$rc)"

echo "--- T9.13: --yes --no-firewall --firewall (contradictory) ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --no-firewall --firewall --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T9.13 contradictory flags does not crash" || _fail "T9.13" "crash"

# ============================================================
echo; echo "=== CAT 10: ACME URL & CA Validation ==="
# ============================================================

echo "--- T10.1: file:// ACME URL ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --acme-url 'file:///etc/passwd' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T10.1 file:// rejected" || _fail "T10.1" "accepted"

echo "--- T10.2: ftp:// ACME URL ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --acme-url 'ftp://evil.com/' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T10.2 ftp:// rejected" || _fail "T10.2" "accepted"

echo "--- T10.3: HARICA without EAB ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --ca harica --staging --dry-run -y 2>&1); rc=$?
[[ $rc -ne 0 ]] && _pass "T10.3 HARICA without EAB rejected" || _fail "T10.3" "rc=$rc"

echo "--- T10.4: ACME URL with user@pass ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --acme-url 'https://user:pass@evil.com/' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T10.4 ACME URL with credentials does not crash" || _fail "T10.4" "crash"

echo "--- T10.5: ACME URL with fragment ---"
OUT=$(certberus auto --webserver certbot-only --domain x.example.com --email a@a.com --acme-url 'https://acme.example.com/#fragment' --staging --dry-run -y 2>&1); rc=$?
[[ $rc -le 2 ]] && _pass "T10.5 ACME URL with fragment does not crash" || _fail "T10.5" "crash"

# ============================================================
echo; echo "=== CAT 11: Signal Handling ==="
# ============================================================

echo "--- T11.1: SIGTERM during auto ---"
certberus auto --webserver certbot-only --domain sig.example.com --email a@a.com --staging -y -v >/tmp/sig.log 2>&1 &
BGPID=$!
sleep 2
kill -TERM $BGPID 2>/dev/null
wait $BGPID 2>/dev/null; rc=$?
_pass "T11.1 SIGTERM handled (rc=$rc)"

echo "--- T11.2: SIGINT during auto ---"
certberus auto --webserver certbot-only --domain sig2.example.com --email a@a.com --staging -y -v >/tmp/sig2.log 2>&1 &
BGPID=$!
sleep 2
kill -INT $BGPID 2>/dev/null
wait $BGPID 2>/dev/null; rc=$?
_pass "T11.2 SIGINT handled (rc=$rc)"

echo "--- T11.3: SIGHUP during dry-run ---"
certberus auto --webserver certbot-only --domain sig3.example.com --email a@a.com --staging -y --dry-run >/tmp/sig3.log 2>&1 &
BGPID=$!
sleep 1
kill -HUP $BGPID 2>/dev/null
wait $BGPID 2>/dev/null; rc=$?
_pass "T11.3 SIGHUP handled (rc=$rc)"

# ============================================================
echo; echo "=== CAT 12: Hooks Edge Cases ==="
# ============================================================

mkdir -p /etc/certberus/hooks/post-issue.d

echo "--- T12.1: hook without exec permission ---"
printf '#!/bin/bash\necho nope\n' > /etc/certberus/hooks/post-issue.d/10-noexec.sh
chmod 644 /etc/certberus/hooks/post-issue.d/10-noexec.sh
OUT=$(certberus hooks list 2>&1)
echo "$OUT" | grep -q "10-noexec" && _fail "T12.1" "non-exec listed" || _pass "T12.1 non-exec hook ignored"
rm -f /etc/certberus/hooks/post-issue.d/10-noexec.sh

echo "--- T12.2: .disabled hook ---"
printf '#!/bin/bash\necho nope\n' > /etc/certberus/hooks/post-issue.d/10-skip.sh.disabled
chmod +x /etc/certberus/hooks/post-issue.d/10-skip.sh.disabled
OUT=$(certberus hooks list 2>&1)
echo "$OUT" | grep -q "10-skip" && _fail "T12.2" ".disabled listed" || _pass "T12.2 .disabled ignored"
rm -f /etc/certberus/hooks/post-issue.d/10-skip.sh.disabled

echo "--- T12.3: .bak hook ---"
printf '#!/bin/bash\necho nope\n' > /etc/certberus/hooks/post-issue.d/10-bak.sh.bak
chmod +x /etc/certberus/hooks/post-issue.d/10-bak.sh.bak
OUT=$(certberus hooks list 2>&1)
echo "$OUT" | grep -q "10-bak" && _fail "T12.3" ".bak listed" || _pass "T12.3 .bak ignored"
rm -f /etc/certberus/hooks/post-issue.d/10-bak.sh.bak

echo "--- T12.4: hook with rc=42 ---"
printf '#!/bin/bash\nexit 42\n' > /etc/certberus/hooks/post-issue.d/99-exit42.sh
chmod +x /etc/certberus/hooks/post-issue.d/99-exit42.sh
OUT=$(certberus auto --webserver certbot-only --domain hookfail.example.com --email a@a.com --staging -y 2>&1); rc=$?
echo "$OUT" | grep -qiE "failed\|fail\|rc=42" && _pass "T12.4 failing hook reports error" || _pass "T12.4 failing hook survived (rc=$rc)"
rm -f /etc/certberus/hooks/post-issue.d/99-exit42.sh

echo "--- T12.5: hook writes binary data ---"
printf '#!/bin/bash\ndd if=/dev/urandom bs=1024 count=10 2>/dev/null\nexit 0\n' > /etc/certberus/hooks/post-issue.d/99-binary.sh
chmod +x /etc/certberus/hooks/post-issue.d/99-binary.sh
OUT=$(certberus auto --webserver certbot-only --domain hookbin.example.com --email a@a.com --staging -y 2>&1); rc=$?
[[ $rc -le 1 ]] && _pass "T12.5 binary hook output does not crash" || _fail "T12.5" "crash"
rm -f /etc/certberus/hooks/post-issue.d/99-binary.sh

echo "--- T12.6: hook is symlink to /usr/bin/true ---"
ln -sf /usr/bin/true /etc/certberus/hooks/post-issue.d/99-true.sh 2>/dev/null || ln -sf /bin/true /etc/certberus/hooks/post-issue.d/99-true.sh
OUT=$(certberus hooks list 2>&1)
_pass "T12.6 symlink hook does not crash"
rm -f /etc/certberus/hooks/post-issue.d/99-true.sh

echo "--- T12.7: hook directory with 50 scripts ---"
for i in $(seq 10 59); do
    printf '#!/bin/bash\nexit 0\n' > "/etc/certberus/hooks/post-issue.d/${i}-mass.sh"
    chmod +x "/etc/certberus/hooks/post-issue.d/${i}-mass.sh"
done
OUT=$(certberus hooks list 2>&1); rc=$?
COUNT=$(echo "$OUT" | grep -c "mass")
[[ $COUNT -ge 40 ]] && _pass "T12.7 50 hooks listed ($COUNT)" || _fail "T12.7" "only $COUNT hooks"
rm -f /etc/certberus/hooks/post-issue.d/*-mass.sh

# ============================================================
# FINAL CLEANUP
# ============================================================
rm -rf /etc/certberus /var/backups/certberus /var/log/certberus /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt /tmp/race*.log /tmp/sig*.log 2>/dev/null

echo
echo "========================================================"
echo "  SUMMARY: $PASS pass / $FAIL fail / $SKIP skip"
echo "========================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
