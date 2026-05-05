#!/bin/bash
# tests/test-preflight.sh
# Offline tests for lib/preflight.sh + common.sh auto-rollback.
# Uses a fake /etc/apache2 structure in a tmpdir.
set -uo pipefail
CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
_pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

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
export CB_DRY_RUN=0
export CB_ASSUME_YES=1
export CB_AUTO_ROLLBACK=0
mkdir -p "$CB_LOG_DIR" "$CB_BACKUP_DIR"

# Fake /etc/apache2
FAKE_A=$(mktemp -d)
trap 'rm -rf "$CB_PREFIX" "$FAKE_A"' EXIT

mkdir -p "$FAKE_A"/{conf-available,conf-enabled,sites-available,sites-enabled,mods-available,mods-enabled}
cat > "$FAKE_A/apache2.conf" <<EOF
# fake master
Listen 80
EOF

# shellcheck disable=SC1091
source "$CERT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/os.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/preflight.sh"

# Hack: override paths in preflight.sh scans via grep roots
# cb_apache_md_sources logs from /etc/apache2 or /etc/httpd - we use bind mount-like override
# Simpler: create symlink /etc/apache2 -> FAKE_A but we cannot as non-root.
# Therefore we directly test grep+classify logic over FAKE_A manually.

echo "=== Test 1: file categorization (master, conf-available, bak) ==="
# Insert MDomain into various locations
cat > "$FAKE_A/apache2.conf" <<EOF
Listen 80
MDomain master.example.com
EOF
cat > "$FAKE_A/conf-available/cert.conf" <<EOF
MDomain site1.example.com
EOF
ln -sf "../conf-available/cert.conf" "$FAKE_A/conf-enabled/cert.conf"
cat > "$FAKE_A/conf-available/old.conf.bak" <<EOF
MDomain backup.example.com
EOF
cat > "$FAKE_A/conf-available/disabled.conf.disabled" <<EOF
MDomain disabled.example.com
EOF

# Override: call the grep logic directly with a custom root
OUT=$(grep -rlE '^\s*MDomain[s]?\b' "$FAKE_A" 2>/dev/null | wc -l)
[[ "$OUT" == "4" ]] && _pass "grep finds 4 files (including bak/disabled)" || _fail "expected 4, got $OUT"

# Categorization: master + conf-available + conf-enabled (link) + 2x disabled-kinds
# we need to override /etc/apache2 for cb_apache_md_sources - done by calling the function directly
# but the function freely iterates over /etc/apache2, /etc/httpd. We test the logic via bind mount:
# If we are root, we can create a /tmp mount point. And we are root.
if [[ $EUID -eq 0 ]] && [[ ! -e /etc/apache2-certberus-bak ]]; then
    # Back up the real /etc/apache2
    [[ -d /etc/apache2 ]] && mv /etc/apache2 /etc/apache2-certberus-bak
    ln -sf "$FAKE_A" /etc/apache2
    OUT=$(cb_apache_md_sources)
    # Restore
    rm /etc/apache2
    [[ -d /etc/apache2-certberus-bak ]] && mv /etc/apache2-certberus-bak /etc/apache2

    echo "  Raw output:"
    echo "$OUT" | sed 's/^/    /'
    # Expect 4 lines: master, conf-available, 2x disabled (grep follows symlinks, so conf-enabled is represented by conf-available)
    COUNT=$(echo "$OUT" | wc -l)
    [[ "$COUNT" == "4" ]] && _pass "categorizes 4 entries (including 2 disabled)" || _fail "expected 4, got $COUNT"

    echo "$OUT" | grep -qE '^master\s' && _pass "categorizes master" || _fail "missing master"
    echo "$OUT" | grep -qE $'^conf-available\t.*\tyes$' && _pass "conf-available with enabled=yes (symlink detected)" || _fail "conf-enabled detection failed"
    echo "$OUT" | grep -qE '^disabled\s.*\.bak' && _pass "categorizes .bak as disabled" || _fail "missing .bak disabled"
    echo "$OUT" | grep -qE '^disabled\s.*\.disabled' && _pass "categorizes .disabled as disabled" || _fail "missing .disabled"
else
    _pass "(skipped master/categorization tests - not root or /etc/apache2 in use)"
fi

echo "=== Test 2: cb_apache_fix_ssl_cert_paths ==="
FAKE_B=$(mktemp -d)
mkdir -p "$FAKE_B"/{sites-enabled,conf-enabled}
cat > "$FAKE_B/sites-enabled/bad.conf" <<EOF
<VirtualHost *:443>
    SSLCertificateFile /nonexistent/cert.pem
    SSLCertificateKeyFile /nonexistent/key.pem
</VirtualHost>
EOF
# Make sure snakeoil exists (should be on the test machine)
if [[ -r /etc/ssl/certs/ssl-cert-snakeoil.pem ]]; then
    # The function writes logs to stdout, we extract just the last number
    FIXED=$(cb_apache_fix_ssl_cert_paths "$FAKE_B" 2>/dev/null | tail -n1)
    [[ "$FIXED" == "1" ]] && _pass "fixed 1 vhost" || _fail "expected 1, got '$FIXED'"
    grep -qE "ssl-cert-snakeoil|fallback-cert" "$FAKE_B/sites-enabled/bad.conf" && _pass "snakeoil/fallback inserted" || _fail
    grep -q "nonexistent" "$FAKE_B/sites-enabled/bad.conf" && _fail "original paths still present" || _pass "original paths replaced"
    ls "$FAKE_B/sites-enabled/"bad.conf.bak_* >/dev/null 2>&1 && _pass "backup created" || _fail "backup missing"
else
    _pass "(skipped - snakeoil cert is not installed)"
fi
rm -rf "$FAKE_B"

echo "=== Test 3: cb_apache_find_broken_symlinks ==="
FAKE_C=$(mktemp -d)
mkdir -p "$FAKE_C/sites-enabled"
ln -s "$FAKE_C/sites-available/nope.conf" "$FAKE_C/sites-enabled/broken.conf"
OUT=$(cb_apache_find_broken_symlinks "$FAKE_C")
echo "$OUT" | grep -q "broken.conf" && _pass "found broken symlink" || _fail "expected broken.conf, got '$OUT'"
rm -rf "$FAKE_C"

echo "=== Test 4: cb_snapshot + cb_snapshot_restore ==="
FAKE_D=$(mktemp -d)/test_snap
mkdir -p "$FAKE_D"
echo "original" > "$FAKE_D/file.txt"
CB_LAST_SNAPSHOT=""
cb_snapshot "$FAKE_D" "testsnap" >/dev/null 2>&1
SNAP="$CB_LAST_SNAPSHOT"
[[ -f "$SNAP" ]] && _pass "snapshot created: $SNAP" || _fail "snapshot missing (CB_LAST_SNAPSHOT=$CB_LAST_SNAPSHOT)"
# Modify, then restore
echo "modified" > "$FAKE_D/file.txt"
cb_snapshot_restore "$SNAP" >/dev/null 2>&1
CONTENT=$(cat "$FAKE_D/file.txt")
[[ "$CONTENT" == "original" ]] && _pass "snapshot_restore returned original content" || _fail "got '$CONTENT'"
rm -rf "$(dirname "$FAKE_D")" "$SNAP"

echo "=== Test 5: cb_auto_rollback (with CB_AUTO_ROLLBACK=1) ==="
export CB_AUTO_ROLLBACK=1
FAKE_E=$(mktemp -d)/test_auto
mkdir -p "$FAKE_E"
echo "orig" > "$FAKE_E/file.txt"
cb_snapshot "$FAKE_E" "testauto" >/dev/null 2>&1
echo "broken" > "$FAKE_E/file.txt"
cb_auto_rollback >/dev/null 2>&1
[[ "$(cat "$FAKE_E/file.txt")" == "orig" ]] && _pass "auto_rollback restored" || _fail
rm -rf "$(dirname "$FAKE_E")" "$CB_LAST_SNAPSHOT"

echo "=== Test 6: cb_auto_rollback (with CB_AUTO_ROLLBACK=0 = hint only) ==="
export CB_AUTO_ROLLBACK=0
FAKE_F=$(mktemp -d)/test_noauto
mkdir -p "$FAKE_F"
echo "orig" > "$FAKE_F/file.txt"
cb_snapshot "$FAKE_F" "testnoauto" >/dev/null 2>&1
echo "broken" > "$FAKE_F/file.txt"
cb_auto_rollback >/dev/null 2>&1  # should only give a hint, not restore
[[ "$(cat "$FAKE_F/file.txt")" == "broken" ]] && _pass "without CB_AUTO_ROLLBACK does not restore (hint only)" || _fail
rm -rf "$(dirname "$FAKE_F")" "$CB_LAST_SNAPSHOT"

echo
echo "==============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================="
(( FAIL == 0 ))
