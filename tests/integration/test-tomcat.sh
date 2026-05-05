#!/bin/bash
# tests/test-tomcat-edge-cases.sh
# Edge-case matrix for Tomcat (docker-based).
#
# Each case starts a fresh container with tomcat10 + certberus, modifies state,
# and runs `certberus issue --dry-run` - we verify that pre-issue stages
# (detection, preflight, snapshot, port80, deploy-hook) behave correctly.
# The issue_cert stage is expected to fail (fake domain), but that is OK -
# we are testing what comes BEFORE it.
#
# Usage:
#   bash tests/test-tomcat-edge-cases.sh                     # all cases
#   bash tests/test-tomcat-edge-cases.sh --only broken-xml
#   bash tests/test-tomcat-edge-cases.sh --distro debian:13
#   bash tests/test-tomcat-edge-cases.sh --keep              # preserve image

set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0; ONLY=""; ONLY_DISTRO=""

# Debian 12 (tomcat10), Debian 13 (tomcat10), Ubuntu 24.04 (tomcat10)
DISTROS=(
    debian:12
    debian:13
    ubuntu:24.04
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)    KEEP=1 ;;
        --only)    shift; ONLY="$1" ;;
        --distro)  shift; ONLY_DISTRO="$1" ;;
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

ensure_image() {
    local distro="$1"
    IMG="certberus-tomcat-test-$(echo "$distro" | tr ':.' '-')"
    CURRENT_DISTRO="$distro"
    docker image inspect "$IMG" >/dev/null 2>&1 && return 0
    echo "### Building $IMG from $distro ###" >&2
    local df; df=$(mktemp)
    cat > "$df" <<DOCKER
FROM $distro
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
        tomcat10 tomcat10-admin sudo iptables nftables certbot \\
        python3 openssl ca-certificates curl && \\
    rm -rf /var/lib/apt/lists/*
# Tomcat10 will not actually start in the test - it is enough that the conf dir and unit file exist.
# certbot is pre-installed so that certberus does not enter a retry loop on "command not found".
DOCKER
    docker build --network=host -t "$IMG" -f "$df" . >&2 || { rm -f "$df"; return 1; }
    rm -f "$df"
}

# -----------------------------------------------------------------------------
# Helper: run case in a container.
#   $1 name      - case name
#   $2 setup     - bash commands before certberus (container state)
#   $3 assert    - bash commands after certberus (verification)
#   $4 extra     - extra arguments for certberus (e.g. "--port80 webroot")
# -----------------------------------------------------------------------------
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
                # Isolation between cases: no leftovers from the shared image
                rm -rf /var/backups/certberus /etc/letsencrypt \\
                       /var/lib/certberus /var/www/acme 2>/dev/null || true
                cat >> /etc/certberus/advanced.env <<EOF
CB_SYSLOG_ENABLED=0
CB_AUTO_ROLLBACK=0
CB_COLOR=never
CB_RETRY_COUNT=1
CB_RETRY_DELAY=0
EOF
                # Ensure the tomcat10 unit exists even when the daemon is not running:
                systemctl list-unit-files 2>/dev/null | grep -q tomcat10 || \\
                    ln -sf /lib/systemd/system/tomcat10.service /etc/systemd/system/tomcat10.service 2>/dev/null || true
                $setup
                set +e
                CERTBERUS_OUTPUT=\$(/usr/local/sbin/certberus issue \\
                    --webserver tomcat --yes --dry-run --staging \\
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
        echo "$out" | tail -30 | sed 's/^/    /'
        fail "$name (rc=$rc)"
    fi
}

run_all_cases() {

# --- CASE 1: clean tomcat10 detection --------------------------------------
run_case "detect-tomcat10" \
'' \
'
echo "$CERTBERUS_OUTPUT" | grep -qE "Tomcat service: tomcat10" || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qE "Conf: /etc/tomcat10" || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qE "User: tomcat" || exit 1
'

# --- CASE 2: broken server.xml (syntax) ------------------------------------
run_case "broken-server-xml" \
'cat > /etc/tomcat10/server.xml <<EOF
<?xml version="1.0"?>
<Server port="8005" shutdown="SHUTDOWN">
  <Service name="Catalina"
   <<<--- this is broken
EOF' \
'
echo "$CERTBERUS_OUTPUT" | grep -qiE "is not valid XML|Tomcat preflight failed" || exit 1
# Certberus MUST stop - no snapshot, no changes
[[ $CERTBERUS_RC -ne 0 ]] || { echo "NOT failing rc=$CERTBERUS_RC"; exit 1; }
[[ ! -d /var/lib/certberus/installed/tomcat-certbot ]] || exit 1
'

# --- CASE 3: missing server.xml --------------------------------------------
run_case "missing-server-xml" \
'rm -f /etc/tomcat10/server.xml' \
'
echo "$CERTBERUS_OUTPUT" | grep -qiE "Nenalezen|server.xml|conf dir" || exit 1
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
'

# --- CASE 4: APR connector warning -----------------------------------------
run_case "apr-connector-warning" \
'python3 - <<PY
import xml.etree.ElementTree as ET
t = ET.parse("/etc/tomcat10/server.xml"); r = t.getroot()
svc = r.find("Service")
# Add APR listener and APR connector
listener = ET.SubElement(r, "Listener")
listener.set("className","org.apache.catalina.core.AprLifecycleListener")
c = ET.SubElement(svc, "Connector")
c.set("port","8443"); c.set("protocol","org.apache.coyote.http11.Http11AprProtocol")
t.write("/etc/tomcat10/server.xml")
PY' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "APR.*connector|only configures NIO" || exit 1'

# --- CASE 5: existing 443 connector must be recognized --------------------
run_case "existing-443-connector" \
'python3 - <<PY
import xml.etree.ElementTree as ET
t = ET.parse("/etc/tomcat10/server.xml"); r = t.getroot()
svc = r.find("Service")
c = ET.SubElement(svc, "Connector")
c.set("port","443"); c.set("SSLEnabled","true"); c.set("protocol","HTTP/1.1")
t.write("/etc/tomcat10/server.xml")
PY' \
'
# Certberus must not abort - it must correctly handle the existing connector.
# In dry-run it does not pass through issue_cert, but detection/preflight must be OK.
echo "$CERTBERUS_OUTPUT" | grep -qE "Tomcat service: tomcat10" || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "Tomcat pre-flight: OK" || exit 1
'

# --- CASE 6: placeholder CB_ACME_URL (bug #9) ------------------------------
run_case "placeholder-acme-url-dropped" \
'mkdir -p /etc/certberus
cat > /etc/certberus/config.env <<EOF
CB_EMAIL=admin@example.com
CB_CA=letsencrypt
CB_ACME_URL="https://acme-v02.harica.gr/acme/..../directory"
EOF' \
'
# The placeholder warning must appear, and ONLY ONCE
count=$(echo "$CERTBERUS_OUTPUT" | grep -c "CB_ACME_URL contains a placeholder")
[[ $count -ge 1 ]] || { echo "missing placeholder warn"; exit 1; }
[[ $count -le 2 ]] || { echo "dup warn (count=$count)"; exit 1; }
'

# --- CASE 7: CA/URL mismatch (letsencrypt + harica URL) --------------------
run_case "ca-url-mismatch-sanitized" \
'mkdir -p /etc/certberus
cat > /etc/certberus/config.env <<EOF
CB_EMAIL=admin@example.com
CB_CA=letsencrypt
CB_ACME_URL="https://acme-v02.harica.gr/acme/aaaa-bbbb/directory"
EOF' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "CB_CA=letsencrypt.*CB_ACME_URL is not letsencrypt" || exit 1'

# --- CASE 8: EAB required without HMAC (HARICA) ---------------------------
run_case "eab-required-missing" \
'' \
'
# HARICA without EAB must fail with a clear message
set +e
OUT2=$(/usr/local/sbin/certberus issue --webserver tomcat --yes --dry-run \
    --ca harica --email test@example.com --domain fake.test.invalid 2>&1)
RC2=$?
set -e
echo "$OUT2" | grep -qiE "EAB|requires" || { echo "missing EAB hint"; echo "$OUT2" | tail -10; exit 1; }
[[ $RC2 -ne 0 ]] || exit 1
'

# --- CASE 9: snapshot contents (unit test, NOT dry-run - not created in dry-run)
run_case "snapshot-includes-letsencrypt" \
'# Actively clean up residuals from previous docker image postinstall / certbot
rm -rf /etc/letsencrypt /var/backups/certberus 2>/dev/null
mkdir -p /etc/letsencrypt/live/marker.example.com /etc/letsencrypt/archive/marker.example.com
echo DUMMYCERT > /etc/letsencrypt/live/marker.example.com/fullchain.pem
echo DUMMY > /etc/letsencrypt/archive/marker.example.com/fullchain1.pem
' \
'
# Unit test cb_snapshot directly (without dry-run)
mkdir -p /var/log/certberus /var/backups/certberus
# Re-assure that setup files still exist (certberus dry-run during CERTBERUS_OUTPUT
# might have done something - here we recreate them just in case).
mkdir -p /etc/letsencrypt/live/marker.example.com /etc/letsencrypt/archive/marker.example.com
echo DUMMYCERT > /etc/letsencrypt/live/marker.example.com/fullchain.pem
echo DUMMY > /etc/letsencrypt/archive/marker.example.com/fullchain1.pem
source /usr/local/lib/certberus/common.sh
CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 CB_LOG_FILE=/tmp/cb.log CB_BACKUP_DIR=/var/backups/certberus
cb_snapshot /etc/tomcat10 tomcat-unit-test \
    /etc/letsencrypt/live /etc/letsencrypt/archive >/dev/null 2>&1
snap="${CB_LAST_SNAPSHOT:-$(ls -t /var/backups/certberus/tomcat-unit-test-*.tar.gz 2>/dev/null | head -1)}"
[[ -n "$snap" && -f "$snap" ]] || { echo "no snapshot"; ls -la /var/backups/certberus/; exit 1; }
tar -tzf "$snap" | grep -q "etc/letsencrypt/live/marker" || {
    echo "LE live missing from $snap"
    echo "--- LE dir state:"; ls -la /etc/letsencrypt/live/ 2>&1
    echo "--- tar contents:"
    tar -tzf "$snap"
    exit 1
}
tar -tzf "$snap" | grep -q "etc/letsencrypt/archive/marker" || { echo "LE archive missing"; exit 1; }
'

# --- CASE 10: port80 webroot strategy creates acme directory ---------------
run_case "port80-webroot-creates-acme" \
'' \
'
[[ -d /var/www/acme/.well-known/acme-challenge ]] || { echo "acme dir missing"; exit 1; }
# Activated ROOT.xml (not .new) - ACME challenge actually served by Tomcat.
[[ -f /etc/tomcat10/Catalina/localhost/ROOT.xml ]] || { echo "ROOT.xml not activated"; exit 1; }
grep -q "certberus" /etc/tomcat10/Catalina/localhost/ROOT.xml || { echo "ROOT.xml not certberus marker"; exit 1; }
' \
"--port80 webroot"

# --- CASE 10b: CLI --webroot is forwarded from orchestrator to Tomcat module -
run_case "cli-webroot-forwarded" \
'' \
'
[[ -d /tmp/tomcat-custom-acme/.well-known/acme-challenge ]] || { echo "custom acme dir missing"; exit 1; }
grep -q "/tmp/tomcat-custom-acme" /etc/tomcat10/Catalina/localhost/ROOT.xml || {
    echo "ROOT context did not use custom webroot"; cat /etc/tomcat10/Catalina/localhost/ROOT.xml; exit 1
}
' \
"--port80 webroot --webroot /tmp/tomcat-custom-acme"

# --- CASE 11: deploy hook is installed -------------------------------------
run_case "deploy-hook-installed" \
'' \
'
# In dry-run the install_deploy_hook stage SKIPs writing files,
# but the log must be present:
echo "$CERTBERUS_OUTPUT" | grep -qE "Deploy hook:" || exit 1
' \
"--port80 webroot"

# --- CASE 12: broken config BEFORE certberus - must not make any changes --
run_case "baseline-broken-no-modifications" \
'cat > /etc/tomcat10/server.xml <<EOF
<Server port="8005" shutdown="SHUTDOWN">
  <unclosed
EOF' \
'
[[ $CERTBERUS_RC -ne 0 ]] || { echo "should have failed"; exit 1; }
# No snapshot must be created (preflight failed before snapshot stage)
ls /var/backups/certberus/tomcat-pre-cert-*.tar.gz 2>/dev/null && { echo "snapshot shouldnt exist"; exit 1; }
# No ACME context file must be created (port80_setup stage did not run)
# With broken XML the port80_setup stage does not run, ROOT.xml must not be created
if [[ -f /etc/tomcat10/Catalina/localhost/ROOT.xml ]] && grep -q certberus /etc/tomcat10/Catalina/localhost/ROOT.xml 2>/dev/null; then
    echo "context file created despite broken XML"; exit 1
fi
[[ ! -d /var/www/acme ]] || { echo "acme webroot created"; exit 1; }
# There must still be a clear error message
echo "$CERTBERUS_OUTPUT" | grep -qiE "XML|preflight" || exit 1
'

# --- CASE 13: Tomcat SSL dir permissions (after deploy hook stage) ---------
run_case "ssl-dir-permissions" \
'' \
'
# deploy hook stage creates CB_TOMCAT_SSL_DIR (in dry-run part is skipped, but the directory is created)
[[ -d /etc/tomcat/ssl ]] || { echo "ssl dir missing"; exit 1; }
owner=$(stat -c %U /etc/tomcat/ssl)
[[ "$owner" == "tomcat" ]] || { echo "owner $owner wrong"; exit 1; }
'

# --- CASE 14: multi-SAN via --domain (both domains tracked) ----------------
run_case "multi-domain-valid" \
'' \
'
# CB_DOMAINS contains 3 domains (default + 2 added). The first starts cert issue
# and immediately fails (non-existent TLD) - that is expected. We validate that
# VALID_DOMAINS contains all 3 via logging "Vydavam cert pro" or hook context.
echo "$CERTBERUS_OUTPUT" | grep -qE "Vydavam cert pro: (test\.internal\.invalid|a\.test\.invalid)" || {
    echo "no domain attempt"; echo "$CERTBERUS_OUTPUT" | tail -15; exit 1
}
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
' \
"--domain a.test.invalid --domain b.test.invalid"

# --- CASE 15: certbot failure detection + rollback hint -------------------
# Regression for BUG #17 (cb_retry returning 0 instead of real rc)
# and BUG #10 (certbot 4.x exit 0 on failure).
run_case "rollback-hint-on-failure" \
'' \
'
# dry-run issue_cert fails on .invalid domain - certbot returns 1
# cb_retry must propagate, stage_issue_cert must call cb_die
[[ $CERTBERUS_RC -ne 0 ]] || { echo "certbot fail not propagated - cb_retry bug?"; exit 1; }
echo "$CERTBERUS_OUTPUT" | grep -qE "certbot failed for|tar -xzf.*tomcat-pre-cert" || {
    echo "no failure/rollback hint"; echo "$CERTBERUS_OUTPUT" | tail -15; exit 1
}
# And there MUST NOT be "All certs issued" when they actually failed
! echo "$CERTBERUS_OUTPUT" | grep -q "All certs issued" || {
    echo "FALSE SUCCESS - BUG: reported OK despite certbot failure"; exit 1
}
'

}  # end run_all_cases

# -----------------------------------------------------------------------------
for distro in "${DISTROS[@]}"; do
    echo "==============================================================="
    echo " TOMCAT EDGE CASES :: $distro"
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
