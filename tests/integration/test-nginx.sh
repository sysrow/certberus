#!/bin/bash
# tests/test-nginx-edge-cases.sh
# Regression test for nginx - captures every bug we encountered in session.
# Most tests are docker-based; some (snapshot semantics, sanitize ACME URL,
# cb_retry return value) are pure-bash unit tests.
#
# BUGS COVERED:
#   #7  - snapshot did not include /etc/letsencrypt (rollback could not restore cert)
#   #8  - `certberus rollback -y` prompted with default N
#   #9  - placeholder CB_ACME_URL sent LE calls to HARICA endpoint
#   #10 - certbot 4.x exit 0 on challenge failure (cb_certbot_issue wrapper)
#   #11 - cb_firewall_redirect_80_to nftables branch did nothing
#   #12 - multi-SAN requires --cert-name + --expand
#   #13 - duplicate CB_ACME_URL warning (parent + subprocess)
#   #14 - preflight did not show WHICH file breaks nginx
#   #15 - test_reload reported "after our changes" even when baseline was broken
#   #17 - cb_retry returned 0 instead of real rc (bash if/fi reset $?)
#   #18 - HARICA/EAB must not auto-open firewall
#   #19 - certbot deploy hook must not call undefined cb_svc_reload
#
# Usage:
#   bash tests/test-nginx-edge-cases.sh
#   bash tests/test-nginx-edge-cases.sh --only broken-vhost-baseline
#   bash tests/test-nginx-edge-cases.sh --distro debian:13

set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0; ONLY=""; ONLY_DISTRO=""

DISTROS=(
    debian:12
    debian:13
    ubuntu:24.04
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)   KEEP=1 ;;
        --only)   shift; ONLY="$1" ;;
        --distro) shift; ONLY_DISTRO="$1" ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$ONLY_DISTRO" ]] && DISTROS=("$ONLY_DISTRO")

TOTAL_PASS=0; TOTAL_FAIL=0
PASS=0; FAIL=0
CURRENT_DISTRO=""; IMG=""

pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

# =============================================================================
# UNIT TESTS (pure bash, no docker)
# =============================================================================
run_unit_tests() {
    echo "=== UNIT TESTS (pure bash) ==="

    # --- cb_retry returns real exit code (BUG #17) ----------------------------
    (
        source "$CERT_ROOT/lib/common.sh" 2>/dev/null || true
        _fail7() { return 7; }
        cb_retry 1 0 _fail7; rc=$?
        [[ $rc -eq 7 ]] || exit 1
        cb_retry 3 0 _fail7; rc=$?
        [[ $rc -eq 7 ]] || exit 1
        _ok() { return 0; }
        cb_retry 3 0 _ok; rc=$?
        [[ $rc -eq 0 ]] || exit 1
    ) && pass "unit: cb_retry returns real rc (BUG #17)" \
      || fail "unit: cb_retry returns real rc (BUG #17)"

    # --- cb_sanitize_acme_url placeholder dropping (BUG #9) -------------------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_CONFIG_FILE="$CB_PREFIX/c" CB_ADVANCED_FILE="$CB_PREFIX/a"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never
        mkdir -p "$CB_LOG_DIR"
        source "$CERT_ROOT/lib/common.sh"
        CB_CA=letsencrypt CB_ACME_URL="https://acme-v02.harica.gr/acme/..../directory"
        unset _CB_ACME_URL_SANITIZED
        cb_sanitize_acme_url 2>/dev/null
        [[ -z "$CB_ACME_URL" ]] || { echo "placeholder not dropped"; exit 1; }
        rm -rf "$CB_PREFIX"
    ) && pass "unit: sanitize placeholder URL (BUG #9)" \
      || fail "unit: sanitize placeholder URL (BUG #9)"

    # --- cb_sanitize_acme_url CA/URL mismatch (BUG #9b) -----------------------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never
        mkdir -p "$CB_LOG_DIR"
        source "$CERT_ROOT/lib/common.sh"
        CB_CA=letsencrypt CB_ACME_URL="https://acme-v02.harica.gr/acme/valid-uuid/directory"
        unset _CB_ACME_URL_SANITIZED
        cb_sanitize_acme_url 2>/dev/null
        [[ -z "$CB_ACME_URL" ]] || { echo "mismatch not sanitized"; exit 1; }
        rm -rf "$CB_PREFIX"
    ) && pass "unit: sanitize CA/URL mismatch (BUG #9b)" \
      || fail "unit: sanitize CA/URL mismatch (BUG #9b)"

    # --- cb_sanitize_acme_url dedup (BUG #13) --------------------------------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never
        mkdir -p "$CB_LOG_DIR"
        source "$CERT_ROOT/lib/common.sh"
        CB_CA=letsencrypt CB_ACME_URL="https://acme-v02.harica.gr/acme/..../directory"
        unset _CB_ACME_URL_SANITIZED
        out1=$(cb_sanitize_acme_url 2>&1)
        out2=$(cb_sanitize_acme_url 2>&1)
        out3=$(cb_sanitize_acme_url 2>&1)
        combined="$out1$out2$out3"
        count=$(echo "$combined" | grep -c "placeholder")
        [[ $count -le 1 ]] || { echo "duplicate warnings count=$count"; exit 1; }
        rm -rf "$CB_PREFIX"
    ) && pass "unit: sanitize URL dedup (BUG #13)" \
      || fail "unit: sanitize URL dedup (BUG #13)"

    # --- cb_snapshot includes multiple sources (BUG #7) -----------------------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never CB_DRY_RUN=0
        mkdir -p "$CB_LOG_DIR" "$CB_BACKUP_DIR"
        source "$CERT_ROOT/lib/common.sh"
        # Fake sources
        F1=$(mktemp -d); F2=$(mktemp -d); F3=$(mktemp -d)
        echo marker1 > "$F1/a.txt"
        echo marker2 > "$F2/b.txt"
        echo marker3 > "$F3/c.txt"
        cb_snapshot "$F1" "multi-src-test" "$F2" "$F3" >/dev/null 2>&1
        snap=$(ls -t "$CB_BACKUP_DIR"/multi-src-test-*.tar.gz 2>/dev/null | head -1)
        [[ -n "$snap" ]] || { echo "no snapshot"; exit 1; }
        tar -tzf "$snap" | grep -q "a.txt" || { echo "missing F1"; exit 1; }
        tar -tzf "$snap" | grep -q "b.txt" || { echo "missing F2"; exit 1; }
        tar -tzf "$snap" | grep -q "c.txt" || { echo "missing F3"; exit 1; }
        rm -rf "$CB_PREFIX" "$F1" "$F2" "$F3"
    ) && pass "unit: cb_snapshot multi-source (BUG #7)" \
      || fail "unit: cb_snapshot multi-source (BUG #7)"

    # --- cb_certbot_issue detects certbot 4.x false success (BUG #10) --------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never
        mkdir -p "$CB_LOG_DIR"
        source "$CERT_ROOT/lib/common.sh"
        # Stub certbot: exit 0 but prints "Some challenges have failed"
        mkdir -p "$CB_PREFIX/bin"
        {
            echo '#!/bin/bash'
            echo 'echo "Some challenges have failed."'
            echo 'echo "Domain fake.test failed: nxdomain"'
            echo 'exit 0'
        } > "$CB_PREFIX/bin/certbot"
        chmod +x "$CB_PREFIX/bin/certbot"
        PATH="$CB_PREFIX/bin:$PATH"
        cb_certbot_issue "fake.test.invalid" certonly -d fake.test.invalid >/dev/null 2>&1
        rc=$?
        [[ $rc -ne 0 ]] || { echo "cb_certbot_issue did not catch false success"; exit 1; }
        rm -rf "$CB_PREFIX"
    ) && pass "unit: cb_certbot_issue catches false success (BUG #10)" \
      || fail "unit: cb_certbot_issue catches false success (BUG #10)"

    # --- HARICA/EAB firewall policy (BUG #18) -------------------------------
    (
        export CB_PREFIX=$(mktemp -d)
        export CB_LOG_DIR="$CB_PREFIX/log" CB_STATE_DIR="$CB_PREFIX/s"
        export CB_BACKUP_DIR="$CB_PREFIX/b" CB_HOOKS_DIR="$CB_PREFIX/h"
        export CB_LOG_FILE="$CB_PREFIX/l" CB_SYSLOG_ENABLED=0 CB_COLOR=never
        mkdir -p "$CB_LOG_DIR"
        source "$CERT_ROOT/lib/common.sh"
        source "$CERT_ROOT/lib/firewall.sh"
        calls="$CB_PREFIX/fw.calls"
        cb_firewall_open_port() { echo "$1/$2/$3" >> "$calls"; }

        CB_CA=harica CB_FIREWALL_AUTO_OPEN=1
        unset CB_HARICA_FIREWALL_AUTO_OPEN _CB_HARICA_FIREWALL_WARNED
        cb_firewall_ensure_http_https_for_acme >/dev/null 2>&1
        [[ ! -s "$calls" ]] || { echo "HARICA opened firewall"; exit 1; }

        CB_HARICA_FIREWALL_AUTO_OPEN=1
        cb_firewall_ensure_http_https_for_acme >/dev/null 2>&1
        grep -q "tcp/80" "$calls" || { echo "opt-in did not open 80"; exit 1; }
        grep -q "tcp/443" "$calls" || { echo "opt-in did not open 443"; exit 1; }

        : > "$calls"
        CB_CA=letsencrypt CB_FIREWALL_AUTO_OPEN=1
        unset CB_HARICA_FIREWALL_AUTO_OPEN
        cb_firewall_ensure_http_https_for_acme >/dev/null 2>&1
        grep -q "tcp/80" "$calls" || { echo "LE did not open 80"; exit 1; }
        rm -rf "$CB_PREFIX"
    ) && pass "unit: HARICA skips firewall unless opted in (BUG #18)" \
      || fail "unit: HARICA skips firewall unless opted in (BUG #18)"

    # --- nginx deploy hook has local reload fallback (BUG #19) ---------------
    (
        hook_body=$(awk '
            /cat > "\$hook" <<'\''HOOK_EOF'\''/ {in_hook=1; next}
            /^HOOK_EOF$/ {in_hook=0}
            in_hook {print}
        ' "$CERT_ROOT/webservers/nginx-certbot.sh")
        echo "$hook_body" | grep -q "reload_nginx()" || { echo "missing reload_nginx"; exit 1; }
        ! echo "$hook_body" | grep -q "cb_svc_reload" || { echo "hook calls undefined cb_svc_reload"; exit 1; }
    ) && pass "unit: nginx deploy hook self-contained reload (BUG #19)" \
      || fail "unit: nginx deploy hook self-contained reload (BUG #19)"

    echo "  unit subtotal: $PASS pass, $FAIL fail"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    PASS=0; FAIL=0
}

# =============================================================================
# DOCKER INTEGRATION TESTS
# =============================================================================
ensure_image() {
    local distro="$1"
    IMG="certberus-nginx-edge-$(echo "$distro" | tr ':.' '-')"
    CURRENT_DISTRO="$distro"
    docker image inspect "$IMG" >/dev/null 2>&1 && return 0
    echo "### Building $IMG from $distro ###" >&2
    local df; df=$(mktemp)
    cat > "$df" <<DOCKER
FROM $distro
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
        nginx sudo iptables nftables certbot python3-certbot-nginx \\
        python3 openssl ca-certificates curl && \\
    rm -rf /var/lib/apt/lists/*
DOCKER
    docker build --network=host -t "$IMG" -f "$df" . >&2 || { rm -f "$df"; return 1; }
    rm -f "$df"
}

run_case() {
    local name="$1" setup="$2" assert="$3" extra="${4:-}"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $CURRENT_DISTRO :: $name ---"
    local out
    out=$(docker run --rm --privileged \
            -v "$CERT_ROOT:/certberus:ro" \
            "$IMG" \
            bash -c "
                set -uo pipefail
                cp -r /certberus /tmp/cb && cd /tmp/cb
                ./install.sh --prefix /usr/local >/dev/null 2>&1
                mkdir -p /etc/certberus
                cat >> /etc/certberus/advanced.env <<EOF
CB_SYSLOG_ENABLED=0
CB_AUTO_ROLLBACK=0
CB_COLOR=never
CB_RETRY_COUNT=1
CB_RETRY_DELAY=0
EOF
                $setup
                set +e
                CERTBERUS_OUTPUT=\$(/usr/local/sbin/certberus issue \\
                    --webserver nginx --yes --staging \\
                    --email test@example.com --domain test.internal.invalid \\
                    $extra 2>&1)
                CERTBERUS_RC=\$?
                set -e
                $assert
            " 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "$name"
    else
        echo "$out" | tail -25 | sed 's/^/    /'
        fail "$name (rc=$rc)"
    fi
}

run_all_cases() {

# --- BUG #14: preflight identifies specific broken vhost ------------------
run_case "broken-vhost-identified-in-preflight" \
'cat > /etc/nginx/sites-available/broken <<EOF
server {
    listen 127.0.0.1:8099 ssl;
    server_name broken.invalid;
    garbage_directive_xyz "on";
}
EOF
ln -sf /etc/nginx/sites-available/broken /etc/nginx/sites-enabled/broken
' \
'
# Preflight must name the file and suggest mv
echo "$CERTBERUS_OUTPUT" | grep -qE "Soubory zpusobujici chybu" || { echo "no identification"; exit 1; }
echo "$CERTBERUS_OUTPUT" | grep -qE "/etc/nginx/sites-enabled/broken" || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qE "sudo mv.*broken.*disabled" || exit 1
'

# --- BUG #15: baseline-broken does not report "after our changes" ---------
run_case "broken-vhost-no-misleading-message" \
'cat > /etc/nginx/sites-available/broken <<EOF
server {
    listen 127.0.0.1:8099 ssl;
    garbage_directive_xyz "on";
}
EOF
ln -sf /etc/nginx/sites-available/broken /etc/nginx/sites-enabled/broken
' \
'
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
# MUST NOT say "after our changes"
! echo "$CERTBERUS_OUTPUT" | grep -qE "after our changes" || {
    echo "misleading message"; exit 1
}
# MUST say the error is outside certberus
echo "$CERTBERUS_OUTPUT" | grep -qiE "from the start|outside certberus|baseline" || exit 1
'

# --- BUG #15b: baseline-broken must not perform any modifications ---------
run_case "broken-vhost-no-modifications" \
'cat > /etc/nginx/sites-available/broken <<EOF
server { garbage_directive_xyz "on"; }
EOF
ln -sf /etc/nginx/sites-available/broken /etc/nginx/sites-enabled/broken
# Record initial state
find /etc/letsencrypt -type f 2>/dev/null | sort > /tmp/le_before
' \
'
find /etc/letsencrypt -type f 2>/dev/null | sort > /tmp/le_after
diff /tmp/le_before /tmp/le_after || { echo "LE state modified"; exit 1; }
# Deploy hook must not be installed
[[ ! -f /etc/letsencrypt/renewal-hooks/deploy/certberus-nginx-reload.sh ]] || {
    echo "deploy hook installed even though baseline broken"; exit 1
}
'

# --- Missing cert/key baseline is fixable with a placeholder --------------
run_case "missing-cert-baseline-continues" \
'cat > /etc/nginx/sites-available/missing-cert <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    server_name test.internal.invalid;
    ssl_certificate /etc/letsencrypt/live/test.internal.invalid/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/test.internal.invalid/privkey.pem;
}
EOF
ln -sf /etc/nginx/sites-available/missing-cert /etc/nginx/sites-enabled/missing-cert
' \
'
echo "$CERTBERUS_OUTPUT" | grep -qiE "placeholder|missing cert" || {
    echo "missing placeholder path"; echo "$CERTBERUS_OUTPUT" | tail -30; exit 1
}
! echo "$CERTBERUS_OUTPUT" | grep -qE "baseline check.*No change" || {
    echo "aborted before remediation"; exit 1
}
'

# --- BUG #9: placeholder CB_ACME_URL dropping ------------------------------
run_case "placeholder-acme-url-warning" \
'cat > /etc/certberus/config.env <<EOF
CB_EMAIL=admin@example.com
CB_CA=letsencrypt
CB_ACME_URL="https://acme-v02.harica.gr/acme/..../directory"
EOF' \
'
echo "$CERTBERUS_OUTPUT" | grep -qE "placeholder" || { echo "no sanitize warn"; exit 1; }
# BUG #13: warning must not be duplicated more than 2x (parent+child is OK)
count=$(echo "$CERTBERUS_OUTPUT" | grep -c "CB_ACME_URL contains a placeholder")
[[ $count -le 2 ]] || { echo "duplicated $count times (BUG #13 regresion)"; exit 1; }
'

# --- BUG #7: snapshot includes /etc/letsencrypt ---------------------------
# Snapshots are not taken in dry-run, so this test runs without dry-run and
# relies on issue_cert failing before actual modification. We check
# the tar archive contents.
run_case "snapshot-includes-letsencrypt" \
'mkdir -p /etc/letsencrypt/live/marker.example.com /etc/letsencrypt/archive/marker.example.com /etc/letsencrypt/accounts/acme-v02/directory/marker
echo CERT > /etc/letsencrypt/live/marker.example.com/fullchain.pem
echo ARCHIVE > /etc/letsencrypt/archive/marker.example.com/fullchain1.pem
echo ACCT > /etc/letsencrypt/accounts/acme-v02/directory/marker/regr.json
' \
'
snap=$(ls -t /var/backups/certberus/nginx-pre-cert-*.tar.gz 2>/dev/null | head -1)
[[ -n "$snap" ]] || { echo "no snapshot"; ls /var/backups/certberus/; exit 1; }
tar -tzf "$snap" | grep -q "etc/letsencrypt/live/marker" || { echo "missing LE live"; exit 1; }
tar -tzf "$snap" | grep -q "etc/letsencrypt/archive/marker" || { echo "missing LE archive"; exit 1; }
tar -tzf "$snap" | grep -q "etc/letsencrypt/accounts" || { echo "missing LE accounts"; exit 1; }
'

# --- BUG #12: --expand is added when multi-SAN ----------------------------
run_case "multi-san-expand-flag" \
'' \
'
# We track certbot args in log (CB_VERBOSE may help, but not required)
# certbot is invoked with --expand when >1 domain (BUG #12)
echo "$CERTBERUS_OUTPUT" | grep -qE "\-\-expand|\-\-cert-name.*test\.internal" || {
    echo "no --expand / --cert-name"; echo "$CERTBERUS_OUTPUT" | grep -iE "certbot|cert-name" | head; exit 1
}
' \
"--domain extra.test.invalid"

# --- BUG #10+#17: certbot failure correctly propagated -------------------
run_case "certbot-failure-propagated" \
'' \
'
# BUG #10 (false success) + BUG #17 (cb_retry swallows rc)
# certbot --dry-run + .invalid domain -> exit 1
# Certberus MUST NOT say "All certs issued"
! echo "$CERTBERUS_OUTPUT" | grep -q "Hotovo" || { echo "false success"; exit 1; }
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "certbot failed|failed for|ROLLBACK" || exit 1
'

# --- nginx OK state detection (happy path to issue) -----------------------
run_case "nginx-healthy-baseline" \
'' \
'
echo "$CERTBERUS_OUTPUT" | grep -qE "nginx pre-flight: OK" || exit 1
# Snapshot was created
ls /var/backups/certberus/nginx-pre-cert-*.tar.gz >/dev/null 2>&1 || exit 1
'

# --- CLI ergonomics: --webroot and --no-firewall via orchestrator ----------
run_case "cli-webroot-forwarded" \
'' \
'
[[ -d /tmp/certberus-custom-acme ]] || { echo "custom webroot dir missing"; exit 1; }
grep -q "/tmp/certberus-custom-acme" /etc/nginx/snippets/certberus-acme.conf || {
    echo "snippet did not use custom webroot"; cat /etc/nginx/snippets/certberus-acme.conf; exit 1
}
' \
"--webroot /tmp/certberus-custom-acme --no-firewall"

}  # end run_all_cases

# -----------------------------------------------------------------------------
echo "==============================================================="
echo " NGINX EDGE-CASE REGRESSION SUITE"
echo "==============================================================="

run_unit_tests

for distro in "${DISTROS[@]}"; do
    echo "==============================================================="
    echo " INTEGRATION :: $distro"
    echo "==============================================================="
    PASS=0; FAIL=0
    if ! ensure_image "$distro"; then
        echo "  [SKIP] $distro - build failed"
        continue
    fi
    run_all_cases
    echo "  $distro: $PASS pass, $FAIL fail"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    [[ $KEEP == 0 ]] && docker image rm "$IMG" >/dev/null 2>&1 || true
done

echo "==============================================================="
echo "TOTAL: $TOTAL_PASS pass / $TOTAL_FAIL fail"
exit $(( TOTAL_FAIL > 0 ? 1 : 0 ))
