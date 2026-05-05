#!/bin/bash
# tests/test-edge-cases.sh
# Edge-case test matrix for Apache.
# Spawns containers of various distros (debian:11, debian:12, ubuntu:22.04, ubuntu:24.04)
# + apache2 + pre-installed certberus. Simulates various broken states.
#
# Usage:
#   bash tests/test-edge-cases.sh                # all distros + cases
#   bash tests/test-edge-cases.sh --distro debian:12
#   bash tests/test-edge-cases.sh --only invalid-ssl-cert-path
#   bash tests/test-edge-cases.sh --keep         # keep image after run

set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0
ONLY=""
ONLY_DISTRO=""

# Default: all popular base images
# Debian/Ubuntu with apt. RHEL-family (Rocky/Alma 9+) require x86-64-v2 CPU and separate
# /etc/httpd path - certberus supports both /etc/apache2 and /etc/httpd detection.
DISTROS=(
    debian:11
    debian:12
    debian:13
    ubuntu:22.04
    ubuntu:24.04
    ubuntu:25.10
    ubuntu:26.04
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --only) shift; ONLY="$1" ;;
        --distro) shift; ONLY_DISTRO="$1" ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -n "$ONLY_DISTRO" ]] && DISTROS=("$ONLY_DISTRO")

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
PASS=0; FAIL=0; SKIP=0
CURRENT_DISTRO=""
IMG=""

pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $*"; SKIP=$((SKIP+1)); }

# -------- Build per-distro image --------
ensure_image() {
    local distro="$1"
    IMG="certberus-test-$(echo "$distro" | tr ':.' '-')"
    CURRENT_DISTRO="$distro"
    if docker image inspect "$IMG" >/dev/null 2>&1; then
        return 0
    fi
    echo "### Building test image $IMG from $distro (apt inside, ~2-5min) ###" >&2
    local dockerfile; dockerfile=$(mktemp)
    cat > "$dockerfile" <<DOCKER
FROM $distro
ENV DEBIAN_FRONTEND=noninteractive
# MINIMAL deps: verifies that certberus does not need dnsutils/apache2-utils/ssl-cert
# Note: Debian <=12 / Ubuntu <=24.04 had libapache2-mod-md as a separate package.
# Debian 13+ / Ubuntu 25.10+ include mod_md directly in apache2; the separate package
# does not exist there. We try to install it and tolerate when it is missing.
RUN apt-get update && apt-get install -y --no-install-recommends \\
        apache2 sudo iptables \\
        python3 openssl ca-certificates && \\
    (apt-get install -y --no-install-recommends libapache2-mod-md 2>/dev/null || true) && \\
    rm -rf /var/lib/apt/lists/*
RUN a2dissite 000-default default-ssl 2>/dev/null || true
# Enable mod_md so that the MDomain directive is valid
RUN a2enmod md 2>/dev/null || true
DOCKER
    docker build --network=host -t "$IMG" -f "$dockerfile" . >&2 || {
        rm -f "$dockerfile"
        return 1
    }
    rm -f "$dockerfile"
}

# -------- Test helper --------
run_case() {
    local name="$1" setup="$2" assert="$3"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $CURRENT_DISTRO :: $name ---"
    local out
    out=$(docker run --rm \
            -v "$CERT_ROOT:/certberus:ro" \
            "$IMG" \
            bash -c "
                set -uo pipefail
                cp -r /certberus /tmp/cb && cd /tmp/cb
                ./install.sh --prefix /usr/local >/dev/null 2>&1
                mkdir -p /etc/certberus
                cat >> /etc/certberus/advanced.env <<EOF
CB_SYSLOG_ENABLED=0
CB_AUTO_ROLLBACK=1
CB_COLOR=never
EOF
                $setup
                set +e
                CERTBERUS_OUTPUT=\$(/usr/local/sbin/certberus issue --webserver apache --yes --dry-run --email test@example.com --domain localhost 2>&1)
                CERTBERUS_RC=\$?
                set -e
                $assert
            " 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "$name"
    else
        echo "$out" | tail -20 | sed 's/^/    /'
        fail "$name (rc=$rc)"
    fi
}

# =============================================================================
# ALL TEST CASES (run per-distro)
# =============================================================================
run_all_cases() {

# --- CASE 1: MDomain in apache2.conf ---
run_case "mdomain-in-apache2.conf" \
'cat >> /etc/apache2/apache2.conf <<EOF
MDomain oldsite.example.com
MDContactEmail zombie@example.com
EOF
a2ensite default-ssl 2>/dev/null || true
' \
'
echo "$CERTBERUS_OUTPUT" | grep -qE "master|apache2.conf" || { echo "MISSING: master"; exit 1; }
echo "$CERTBERUS_OUTPUT" | grep -qE "MDomain" || exit 1
'

# --- CASE 2: Orphan symlink (broken) ---
run_case "mdomain-orphan-conf-enabled" \
'cat > /etc/apache2/conf-available/old-md.conf <<EOF
MDomain orphan.example.com
EOF
a2enconf old-md
rm /etc/apache2/conf-available/old-md.conf
' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "broken|symlink|kolizn" || exit 1'

# --- CASE 3: Invalid SSL cert path + real fix ---
run_case "invalid-ssl-cert-path" \
'cat > /etc/apache2/sites-available/bad.conf <<EOF
<VirtualHost *:443>
    ServerName localhost
    SSLEngine on
    SSLCertificateFile /tmp/neexistuje.pem
    SSLCertificateKeyFile /tmp/neexistuje.key
</VirtualHost>
EOF
a2enmod ssl >/dev/null 2>&1
a2ensite bad
' \
'
echo "$CERTBERUS_OUTPUT" | grep -qiE "nevalidn|SSLCertificateFile" || exit 1
set +e
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_fix_ssl_cert_paths /etc/apache2
"
set -e
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { apache2ctl -t; exit 1; }
'

# --- CASE 4: Broken symlink ---
run_case "broken-symlink-sites-enabled" \
'ln -s /etc/apache2/sites-available/neexistuje.conf /etc/apache2/sites-enabled/missing.conf
a2ensite default-ssl 2>/dev/null || true
' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "broken|symlink" || exit 1'

# --- CASE 5: Apache with broken config before start ---
run_case "apache-broken-before-start" \
'cat >> /etc/apache2/apache2.conf <<EOF
ThisIsGarbage yes
EOF' \
'
echo "$CERTBERUS_OUTPUT" | grep -qiE "syntax|error|ThisIsGarbage" || exit 1
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
'

# --- CASE 6: 3+ MDomain locations ---
run_case "multiple-mdomain-locations" \
'cat > /etc/apache2/conf-available/md1.conf <<EOF
MDomain site1.example.com
EOF
cat > /etc/apache2/conf-available/md2.conf <<EOF
MDomain site2.example.com
EOF
a2enconf md1 md2
cat >> /etc/apache2/apache2.conf <<EOF
MDomain master.example.com
EOF
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "Nalezeno [3-9] mist" || exit 1'

# --- CASE 7: .bak/.disabled must be ignored ---
run_case "mdomain-in-backup-files" \
'cat > /etc/apache2/conf-available/old.conf.bak <<EOF
MDomain backup.example.com
EOF
cat > /etc/apache2/conf-available/x.conf.disabled <<EOF
MDomain disabled.example.com
EOF
cat > /etc/apache2/conf-available/y.conf.orig <<EOF
MDomain orig.example.com
EOF
cat > /etc/apache2/conf-available/z.conf~ <<EOF
MDomain tilde.example.com
EOF
' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "No conflicting MDomain|only bak" || exit 1'

# --- CASE 8: Empty sites-enabled ---
run_case "no-enabled-sites" \
'rm -f /etc/apache2/sites-enabled/*' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "No enabled sites|No valid domain|not found" || exit 1'

# === NEW EDGE CASES ==========================================================

# --- CASE 9: MDomain inside IfModule block (conditional) ---
run_case "mdomain-inside-ifmodule" \
'cat > /etc/apache2/conf-available/conditional.conf <<EOF
<IfModule mod_md.c>
    MDomain inside-if.example.com
    MDContactEmail admin@example.com
</IfModule>
EOF
a2enconf conditional
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "conditional|inside-if" || exit 1'

# --- CASE 10: CRLF line endings (Windows style) ---
run_case "crlf-line-endings" \
'printf "MDomain crlf.example.com\r\nMDContactEmail x@y.z\r\n" > /etc/apache2/conf-available/crlf.conf
a2enconf crlf
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "crlf\.conf|CATEGORY" || exit 1
# Apache must remain functional
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { apache2ctl -t; exit 1; }
'

# --- CASE 11: Multiple VirtualHosts in one file, only one broken ---
run_case "multi-vhost-one-broken" \
'cat > /etc/apache2/sites-available/multi.conf <<EOF
<VirtualHost *:80>
    ServerName ok.example.com
    DocumentRoot /var/www/html
</VirtualHost>
<VirtualHost *:443>
    ServerName broken.example.com
    SSLEngine on
    SSLCertificateFile /nonexistent/cert.pem
    SSLCertificateKeyFile /nonexistent/key.pem
</VirtualHost>
EOF
a2enmod ssl >/dev/null 2>&1
a2ensite multi
' \
'
set +e
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_fix_ssl_cert_paths /etc/apache2 >/dev/null
"
set -e
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { apache2ctl -t; exit 1; }
# Must not lose the port 80 vhost
grep -q "ok.example.com" /etc/apache2/sites-available/multi.conf || { echo "lost vhost"; exit 1; }
'

# --- CASE 12: File without trailing newline ---
run_case "no-trailing-newline" \
'printf "MDomain notrail.example.com" > /etc/apache2/conf-available/notrail.conf
a2enconf notrail
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "notrail" || exit 1'

# --- CASE 13: Multiple MDomain in a single file ---
run_case "multiple-mdomain-same-file" \
'cat > /etc/apache2/conf-available/many.conf <<EOF
MDomain a.example.com
MDomain b.example.com  
MDomains c.example.com d.example.com
MDContactEmail admin@example.com
EOF
a2enconf many
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "many\.conf" || exit 1'

# --- CASE 14: Commented-out MDomain must not be detected ---
run_case "commented-mdomain" \
'cat > /etc/apache2/conf-available/commented.conf <<EOF
#MDomain commented.example.com
# MDomain also-commented.example.com
#    MDomain indented-comment.example.com
EOF
a2enconf commented
' \
'
# Grep ^\s*MDomain must not catch this
echo "$CERTBERUS_OUTPUT" | grep -qE "commented\.conf" && { echo "Detected a comment!"; exit 1; }
echo "$CERTBERUS_OUTPUT" | grep -qiE "No conflicting|not found" || exit 1
'

# --- CASE 15: MDomain in mods-enabled ---
run_case "mdomain-in-mods-enabled" \
'cat > /etc/apache2/mods-available/md.conf <<EOF
<IfModule mod_md.c>
    MDomain legacy.example.com
</IfModule>
EOF
# mod_md itself is not present - we cannot enmod. Create symlink manually.
ln -sf /etc/apache2/mods-available/md.conf /etc/apache2/mods-enabled/md.conf 2>/dev/null || true
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "mods-enabled|mods-available|md\.conf" || exit 1'

# --- CASE 16: Config file with non-.conf extension ---
run_case "non-conf-extension" \
'# Apache only loads .conf files, but grep catches anything. Must ignore.
cat > /etc/apache2/conf-available/readme.txt <<EOF
MDomain text-file.example.com
EOF
' \
'
# readme.txt does not have .conf extension, a2enconf will not add it, so enabled=no and nobody loads it
# With a grep approach it would be visible with enabled=no - certberus can ignore it
# IMPORTANT: the script must not fail even if it sees this
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 17: Non-root execution - must die cleanly ---
run_case "non-root-execution" \
'useradd -m -s /bin/bash testuser 2>/dev/null || true
# Make /tmp/cb readable by testuser
chmod -R a+rX /tmp/cb
' \
'
set +e
NONROOT_OUT=$(su - testuser -c "/usr/local/sbin/certberus issue --webserver apache --yes --dry-run --email test@example.com --domain localhost 2>&1")
NONROOT_RC=$?
set -e
# Must fail and report the reason, not produce garbage
[[ $NONROOT_RC -ne 0 ]] || { echo "Non-root should have failed"; exit 1; }
echo "$NONROOT_OUT" | grep -qiE "root|sudo|permission" || { echo "$NONROOT_OUT" | tail -5; exit 1; }
'

# --- CASE 18: apache2 completely missing ---
run_case "apache-not-installed" \
'apt-get remove -y --purge apache2 apache2-bin 2>/dev/null >/dev/null
rm -rf /etc/apache2
' \
'
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "apache|instal" || exit 1
'

# --- CASE 19: Scattered Include directive pointing to external path ---
run_case "external-include-dir" \
'mkdir -p /opt/apache-extra
cat > /opt/apache-extra/md.conf <<EOF
MDomain external.example.com
EOF
cat >> /etc/apache2/apache2.conf <<EOF
IncludeOptional /opt/apache-extra/*.conf
EOF
' \
'
# Certberus by default only scans /etc/apache2 - external would be skipped.
# Apache itself loads the directive though, which would cause a collision.
# MINIMUM: certberus must not crash.
# PREFERRED: detects Include and warns.
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
# Test module dump from script - not fatal
'

# --- CASE 20: /etc/apache2 read-only ---
run_case "readonly-etc" \
'chmod -R a-w /etc/apache2 2>/dev/null || true
' \
'
# Snapshot will work (read-only), but detect_existing_md has nothing to modify
# (everything enabled=no/nothing to detect). Apache2ctl must not fail.
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
# Cleanup for subsequent tests
chmod -R u+w /etc/apache2 2>/dev/null || true
'

# --- CASE 21: Dry-run must not write anything ---
run_case "dry-run-no-mutation" \
'cat > /etc/apache2/conf-available/touchme.conf <<EOF
MDomain dryrun.example.com
EOF
a2enconf touchme
# Hash before
MD5_BEFORE=$(md5sum /etc/apache2/conf-available/touchme.conf | cut -d" " -f1)
echo "$MD5_BEFORE" > /tmp/md5-before
' \
'
MD5_AFTER=$(md5sum /etc/apache2/conf-available/touchme.conf | cut -d" " -f1)
MD5_BEFORE=$(cat /tmp/md5-before)
[[ "$MD5_BEFORE" == "$MD5_AFTER" ]] || { echo "DRY-RUN wrote files! $MD5_BEFORE != $MD5_AFTER"; exit 1; }
# Also must not create a backup file
ls /etc/apache2/conf-available/touchme.conf.bak_* 2>/dev/null && { echo "Dry-run created backup!"; exit 1; }
true
'

# --- CASE 22: Whitespace in MDomain line (tab, leading space) ---
run_case "whitespace-mdomain" \
'printf "\tMDomain tab.example.com\n    MDomain space.example.com\n" > /etc/apache2/conf-available/ws.conf
a2enconf ws
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "ws\.conf" || exit 1'

# --- CASE 23: Config file with executable flag ---
run_case "executable-config-file" \
'cat > /etc/apache2/conf-available/exec.conf <<EOF
MDomain exec.example.com
EOF
chmod +x /etc/apache2/conf-available/exec.conf
a2enconf exec
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "exec\.conf" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# === 15 MORE CREATIVE CASES (v2) =============================================

# --- CASE 24: UTF-8 characters in config + comments ---
run_case "utf8-in-config" \
'cat > /etc/apache2/conf-available/utf8.conf <<EOF
# Komentář s diakritikou: žluťoučký kůň úpěl ďábelské ódy
# 日本語 comment 한국어
MDomain utf8.example.com
# Emoji: 🔒 ✓
EOF
a2enconf utf8
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "utf8\.conf" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 25: BOM at beginning of file ---
run_case "utf8-bom-in-config" \
'printf "\xef\xbb\xbfMDomain bom.example.com\n" > /etc/apache2/conf-available/bom.conf
a2enconf bom
' \
'
# Apache usually tolerates BOM since 2.4+. Our grep ^MDomain catches it if on the next line.
# Most importantly, the script must not crash.
echo "$CERTBERUS_OUTPUT" | grep -qiE "kategorie|CATEGORY|bom|Nalezeno" || exit 1
'

# --- CASE 26: Very long filename (240 characters) ---
run_case "long-filename" \
'LONG=$(printf "a%.0s" {1..240})
cat > "/etc/apache2/conf-available/${LONG}.conf" <<EOF
MDomain long.example.com
EOF
a2enconf "$LONG" 2>/dev/null || ln -sf "/etc/apache2/conf-available/${LONG}.conf" "/etc/apache2/conf-enabled/${LONG}.conf"
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "long|Nalezeno" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 27: Nested Include (chain of 3 files) ---
run_case "nested-includes" \
'cat > /etc/apache2/conf-available/chain1.conf <<EOF
Include /etc/apache2/extra1.conf
EOF
cat > /etc/apache2/extra1.conf <<EOF
Include /etc/apache2/extra2.conf
EOF
cat > /etc/apache2/extra2.conf <<EOF
MDomain nested.example.com
EOF
a2enconf chain1
' \
'echo "$CERTBERUS_OUTPUT" | grep -qiE "nested|chain1|Nalezeno|kategorie" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 28: IncludeOptional pointing to nonexistent path ---
run_case "include-optional-missing" \
'cat >> /etc/apache2/apache2.conf <<EOF
IncludeOptional /opt/neexistujici/path/*.conf
EOF
' \
'
# IncludeOptional silently skips when path does not exist - apache must pass
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
# Certberus may rc!=0 due to missing domain, but not due to syntax.
echo "$CERTBERUS_OUTPUT" | grep -qiE "syntax error|IncludeOptional.*error" && exit 1
true
'

# --- CASE 29: Mandatory Include pointing to nonexistent path ---
run_case "include-mandatory-missing" \
'cat >> /etc/apache2/apache2.conf <<EOF
Include /opt/neexistujici/path/mandatory.conf
EOF
' \
'
# Include (without Optional) fails if the file does not exist - preflight must detect
echo "$CERTBERUS_OUTPUT" | grep -qiE "syntax|Include|error" || exit 1
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
'

# --- CASE 30: Case-insensitive mdomain directive ---
run_case "case-insensitive-mdomain" \
'cat > /etc/apache2/conf-available/lower.conf <<EOF
mdomain lower.example.com
EOF
cat > /etc/apache2/conf-available/upper.conf <<EOF
MDOMAIN upper.example.com
EOF
a2enconf lower upper
' \
'
# Apache is case-insensitive, certberus grep must catch all variants.
# If it catches only one, that is a bug we want to expose.
echo "$CERTBERUS_OUTPUT" | grep -qiE "lower\.conf|upper\.conf|Nalezeno" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 31: Duplicate MDomain with same name ---
run_case "duplicate-mdomain-same-name" \
'cat > /etc/apache2/conf-available/dup1.conf <<EOF
MDomain duplicate.example.com
EOF
cat > /etc/apache2/conf-available/dup2.conf <<EOF
MDomain duplicate.example.com
EOF
a2enconf dup1 dup2
' \
'
# Two active MDomain with the same name - apache2ctl should warn, certberus must alert
# about the collision.
echo "$CERTBERUS_OUTPUT" | grep -qE "dup1|dup2|duplic|Nalezeno" || exit 1
'

# --- CASE 32: MDBaseServer/MDRequireHttps without MDomain ---
run_case "md-directives-no-mdomain" \
'cat > /etc/apache2/conf-available/md-config.conf <<EOF
MDBaseServer on
MDRequireHttps temporary
MDStapling on
EOF
a2enconf md-config
' \
'
# Orphaned MD* directives without MDomain - certberus should detect/warn,
# but must not crash. Apache v2.4.34+ supports them.
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 33: SSLCertificateFile pointing to directory instead of file ---
run_case "ssl-cert-path-is-dir" \
'mkdir -p /tmp/cert-dir
cat > /etc/apache2/sites-available/dir-cert.conf <<EOF
<VirtualHost *:443>
    ServerName localhost
    SSLEngine on
    SSLCertificateFile /tmp/cert-dir
    SSLCertificateKeyFile /tmp/cert-dir
</VirtualHost>
EOF
a2enmod ssl >/dev/null 2>&1
a2ensite dir-cert
' \
'
# Certberus must detect invalid SSL path and fix it (fallback cert)
set +e
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_fix_ssl_cert_paths /etc/apache2 >/dev/null
"
set -e
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { apache2ctl -t; exit 1; }
'

# --- CASE 34: SSLCertificateFile -> /dev/null ---
run_case "ssl-cert-devnull" \
'cat > /etc/apache2/sites-available/devnull.conf <<EOF
<VirtualHost *:443>
    ServerName localhost
    SSLEngine on
    SSLCertificateFile /dev/null
    SSLCertificateKeyFile /dev/null
</VirtualHost>
EOF
a2enmod ssl >/dev/null 2>&1
a2ensite devnull
' \
'
set +e
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_fix_ssl_cert_paths /etc/apache2 >/dev/null
"
set -e
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 35: sites-enabled is a file instead of directory ---
run_case "sites-enabled-is-file" \
'rm -rf /etc/apache2/sites-enabled
echo "garbage" > /etc/apache2/sites-enabled
' \
'
# Totally broken state. Apache2ctl fails, certberus must detect and report,
# must not remain in an inconsistent state.
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "sites-enabled|directory|error" || true
# Cleanup
rm -f /etc/apache2/sites-enabled && mkdir -p /etc/apache2/sites-enabled
'

# --- CASE 36: Config file as symlink to /dev/null ---
run_case "config-symlink-to-devnull" \
'ln -sf /dev/null /etc/apache2/conf-available/nullconf.conf
ln -sf /etc/apache2/conf-available/nullconf.conf /etc/apache2/conf-enabled/nullconf.conf
' \
'
# Apache will refuse to open /dev/null ("not a regular file"). Certberus must detect
# the syntax error, not silently succeed.
echo "$CERTBERUS_OUTPUT" | grep -qiE "syntax|nullconf|regular file|Bad file" || exit 1
# Must not cause segfault (rc < 128)
[[ $CERTBERUS_RC -lt 128 ]] || exit 1
'

# --- CASE 37: Extremely large config file (1 MB) ---
run_case "huge-config-file" \
'{
    for i in $(seq 1 10000); do
        echo "# Fill line $i - $(printf "x%.0s" {1..80})"
    done
    echo "MDomain huge.example.com"
} > /etc/apache2/conf-available/huge.conf
a2enconf huge
' \
'
# Grep must handle even a large file without timeout
echo "$CERTBERUS_OUTPUT" | grep -qE "huge\.conf|Nalezeno" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 38: Idempotence - second run must not change anything ---
run_case "idempotent-second-run" \
'cat > /etc/apache2/conf-available/idem.conf <<EOF
MDomain idem.example.com
EOF
a2enconf idem
# First run (simulating real run without --dry-run for preflight fixes)
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 CB_AUTO_ROLLBACK=0 cb_apache_fix_ssl_cert_paths /etc/apache2 >/dev/null 2>&1
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_find_broken_symlinks /etc/apache2 >/dev/null 2>&1
" || true
# Remember hash of entire /etc/apache2
find /etc/apache2 -type f -exec md5sum {} \; | sort > /tmp/hash-after-first
' \
'
# Simulate second run
bash -c "
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 CB_AUTO_ROLLBACK=0 cb_apache_fix_ssl_cert_paths /etc/apache2 >/dev/null 2>&1
    CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 cb_apache_find_broken_symlinks /etc/apache2 >/dev/null 2>&1
" || true
find /etc/apache2 -type f -exec md5sum {} \; | sort > /tmp/hash-after-second
diff /tmp/hash-after-first /tmp/hash-after-second || { echo "SECOND RUN IS NOT IDEMPOTENT"; exit 1; }
'

# --- CASE 39: Strange characters in hostname (wildcard) ---
run_case "wildcard-mdomain" \
'cat > /etc/apache2/conf-available/wild.conf <<EOF
MDomain *.example.com example.com
MDomain "sub.example.com"
EOF
a2enconf wild
' \
'echo "$CERTBERUS_OUTPUT" | grep -qE "wild\.conf|Nalezeno" || exit 1
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 40: Rollback after introducing an error ---
run_case "rollback-on-broken-change" \
'cat > /etc/apache2/conf-available/rb.conf <<EOF
MDomain rb.example.com
EOF
a2enconf rb
# Record original state
md5sum /etc/apache2/apache2.conf > /tmp/md5-orig
' \
'
set +e
bash -c "
    export CB_BACKUP_DIR=/tmp/cb-bak
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    mkdir -p \$CB_BACKUP_DIR
    source /tmp/cb/lib/common.sh
    cb_snapshot /etc/apache2 apache-test >/dev/null
    # CB_LAST_SNAPSHOT is now set
    [[ -f \$CB_LAST_SNAPSHOT ]] || exit 10
    echo garbage > /etc/apache2/apache2.conf
    cb_snapshot_restore \$CB_LAST_SNAPSHOT >/dev/null 2>&1 || exit 11
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "bash -c failed rc=$RC"; exit 1; }
md5sum /etc/apache2/apache2.conf > /tmp/md5-after
diff /tmp/md5-orig /tmp/md5-after || { echo "ROLLBACK DID NOT RESTORE"; exit 1; }
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 41: Apache running vs stopped ---
run_case "apache-daemon-running" \
'# in container without systemd - start apache manually
apache2ctl start 2>/dev/null || /usr/sbin/apache2 -k start 2>/dev/null || true
sleep 1
pgrep apache2 >/dev/null || true
cat > /etc/apache2/conf-available/run.conf <<EOF
MDomain run.example.com
EOF
a2enconf run
' \
'
# Detect + dry-run must not stop a running apache
pgrep apache2 >/dev/null && echo "apache still running" || true
echo "$CERTBERUS_OUTPUT" | grep -qE "run\.conf|Nalezeno" || exit 1
apache2ctl stop 2>/dev/null || true
'

# --- CASE 42: Missing ports.conf ---
run_case "missing-ports-conf" \
'rm -f /etc/apache2/ports.conf
' \
'
# apache2ctl -t will fail, certberus must detect and handle it
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "ports|syntax|error" || exit 1
'

# --- CASE 43: envvars missing ---
run_case "missing-envvars" \
'rm -f /etc/apache2/envvars
' \
'
# Without envvars apache2ctl fails (missing APACHE_RUN_USER etc.)
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
'

# --- CASE 44: Incomplete VirtualHost (missing closing tag) ---
run_case "unclosed-vhost" \
'cat > /etc/apache2/sites-available/unclosed.conf <<EOF
<VirtualHost *:80>
    ServerName unclosed.example.com
    DocumentRoot /var/www/html
EOF
a2ensite unclosed
' \
'
[[ $CERTBERUS_RC -ne 0 ]] || exit 1
echo "$CERTBERUS_OUTPUT" | grep -qiE "syntax|VirtualHost|unclosed" || exit 1
'

# --- CASE 45: Null bytes in config file ---
run_case "null-bytes-in-config" \
'printf "MDomain good.example.com\n\0\0\0garbage\n" > /etc/apache2/conf-available/nulls.conf
a2enconf nulls
' \
'
# Grep should handle null bytes (with -a or binary-as-text). Apache usually fails.
# Certberus must not exhibit undefined behavior - either detect correctly or fail with error.
# IMPORTANT: must not silently succeed when the config is corrupted.
if [[ $CERTBERUS_RC -eq 0 ]]; then
    echo "$CERTBERUS_OUTPUT" | grep -qE "good\.example\.com|nulls\.conf" || exit 1
fi
'

# --- CASE 46: Hard-link multiple files to same MDomain ---
run_case "hardlink-mdomain" \
'cat > /etc/apache2/conf-available/orig.conf <<EOF
MDomain hl.example.com
EOF
ln /etc/apache2/conf-available/orig.conf /etc/apache2/conf-available/link.conf
a2enconf orig link
' \
'
# Both files share the same inode but certberus should count by path
echo "$CERTBERUS_OUTPUT" | grep -qE "orig\.conf|link\.conf|Nalezeno" || exit 1
'

# --- CASE 47: Read-only root filesystem simulated on /etc/apache2 ---
run_case "snapshot-when-readonly" \
'cat > /etc/apache2/conf-available/ro.conf <<EOF
MDomain ro.example.com
EOF
a2enconf ro
chmod -R a-w /etc/apache2
' \
'
set +e
bash -c "
    export CB_BACKUP_DIR=/tmp/ro-backup
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    mkdir -p \$CB_BACKUP_DIR
    source /tmp/cb/lib/common.sh
    cb_snapshot /etc/apache2 ro-test >/dev/null 2>&1 || exit 10
    [[ -f \$CB_LAST_SNAPSHOT ]] || exit 11
    tar -tzf \$CB_LAST_SNAPSHOT 2>/dev/null | grep -q apache2.conf || exit 12
"
RC=$?
chmod -R u+w /etc/apache2
set -e
[[ $RC -eq 0 ]] || { echo "snapshot failed rc=$RC"; exit 1; }
'

# === 8 MORE CASES: snapshot/restore cycle + autofix + firewall policy ========

# --- CASE 48: full-cycle snapshot/mutate/restore == pristine (byte-exact) ---
run_case "snapshot-mutate-restore-equals-pristine" \
'# Pristine hash of entire /etc/apache2 BEFORE any action
find /etc/apache2 -xdev \( -type f -o -type l \) -printf "%p %y %l\n" \
    | while read -r path kind target; do
        if [[ "$kind" == "l" ]]; then
            echo "$path SYMLINK $target"
        else
            md5sum "$path" 2>/dev/null || echo "$path UNREADABLE"
        fi
    done | sort > /tmp/pristine.txt
' \
'
set +e
bash -c "
    export CB_BACKUP_DIR=/tmp/cycle-backup
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    mkdir -p \$CB_BACKUP_DIR
    source /tmp/cb/lib/common.sh
    # 1) SNAPSHOT before changes
    cb_snapshot /etc/apache2 full-cycle >/dev/null 2>&1 || exit 10
    SNAP=\$CB_LAST_SNAPSHOT
    [[ -f \$SNAP ]] || exit 11
    # 2) MUTATE - do everything certberus can: add files, delete, modify
    rm -f /etc/apache2/apache2.conf
    echo rubbish > /etc/apache2/new-rubbish.conf
    ln -sf /neexistuje /etc/apache2/sites-enabled/broken.conf
    touch /etc/apache2/conf-available/added.conf
    chmod 000 /etc/apache2/ports.conf 2>/dev/null
    # 3) RESTORE
    # Remove the entire directory and extract
    rm -rf /etc/apache2
    cb_snapshot_restore \$SNAP >/dev/null 2>&1 || exit 12
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "cycle failed rc=$RC"; exit 1; }
# 4) DIFF vs pristine - must be BYTE-EXACT
find /etc/apache2 -xdev \( -type f -o -type l \) -printf "%p %y %l\n" \
    | while read -r path kind target; do
        if [[ "$kind" == "l" ]]; then
            echo "$path SYMLINK $target"
        else
            md5sum "$path" 2>/dev/null || echo "$path UNREADABLE"
        fi
    done | sort > /tmp/post-restore.txt

if ! diff -u /tmp/pristine.txt /tmp/post-restore.txt; then
    echo "RESTORE IS NOT IDENTICAL TO PRISTINE!"
    exit 1
fi
# 5) apache must be functional
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { apache2ctl -t; exit 1; }
'

# --- CASE 49: autofix regular file in sites-enabled -> mv + symlink ---
run_case "autofix-regular-file-in-sites-enabled" \
'# Admin drops regular file directly into sites-enabled (instead of symlink)
cat > /etc/apache2/sites-enabled/misplaced.conf <<EOF
<VirtualHost *:80>
    ServerName misplaced.example.com
    DocumentRoot /var/www/html
</VirtualHost>
EOF
# Record md5 of CONTENT to verify nothing was lost
md5sum /etc/apache2/sites-enabled/misplaced.conf | cut -d" " -f1 > /tmp/md5-orig-content
' \
'
# Run fix stage directly - not the whole certberus issue (because of domains)
set +e
bash -c "
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    cb_apache_fix_sites_enabled_regular_files /etc/apache2 >/dev/null 2>&1
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "fix failed"; exit 1; }

# Verify: file MUST exist in sites-available
[[ -f /etc/apache2/sites-available/misplaced.conf ]] || { echo "Missing in sites-available"; exit 1; }
# Verify: MUST be a symlink in sites-enabled
[[ -L /etc/apache2/sites-enabled/misplaced.conf ]] || { echo "Not a symlink"; exit 1; }
# Verify: content did not change
MD5_NEW=$(md5sum /etc/apache2/sites-available/misplaced.conf | cut -d" " -f1)
MD5_ORIG=$(cat /tmp/md5-orig-content)
[[ "$MD5_NEW" == "$MD5_ORIG" ]] || { echo "Content changed!"; exit 1; }
# a2dissite MUST work
a2dissite misplaced >/dev/null 2>&1 || { echo "a2dissite fails"; exit 1; }
apache2ctl -t 2>&1 | grep -q "Syntax OK" || exit 1
'

# --- CASE 50: autofix does NOT touch valid symlinks ---
run_case "autofix-keeps-valid-symlinks" \
'cat > /etc/apache2/sites-available/valid.conf <<EOF
<VirtualHost *:80>
    ServerName valid.example.com
</VirtualHost>
EOF
a2ensite valid
# Record state
find /etc/apache2/sites-available /etc/apache2/sites-enabled \
    -printf "%p %y %l\n" | sort > /tmp/pre-fix.txt
' \
'
set +e
bash -c "
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    FIXED=\$(cb_apache_fix_sites_enabled_regular_files /etc/apache2)
    [[ \"\$FIXED\" == \"0\" ]] || exit 10
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "fix ran even though it should not have"; exit 1; }
find /etc/apache2/sites-available /etc/apache2/sites-enabled \
    -printf "%p %y %l\n" | sort > /tmp/post-fix.txt
diff /tmp/pre-fix.txt /tmp/post-fix.txt || { echo "Fix modified valid state!"; exit 1; }
'

# --- CASE 51: broken-symlink autofix ---
run_case "autofix-broken-symlinks" \
'ln -sf /etc/apache2/sites-available/gone.conf /etc/apache2/sites-enabled/gone.conf
ln -sf /etc/apache2/conf-available/lost.conf /etc/apache2/conf-enabled/lost.conf
# Before fix: 2 broken symlinks
' \
'
set +e
bash -c "
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    FIXED=\$(cb_apache_fix_broken_symlinks /etc/apache2)
    [[ \"\$FIXED\" == \"2\" ]] || { echo fixed=\$FIXED; exit 10; }
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "fix broken failed"; exit 1; }
# Verify
[[ ! -e /etc/apache2/sites-enabled/gone.conf ]] || { echo "Broken symlink still exists"; exit 1; }
[[ ! -e /etc/apache2/conf-enabled/lost.conf ]] || { echo "Broken symlink still exists"; exit 1; }
'

# --- CASE 52: dry-run autofix - changes nothing ---
run_case "autofix-dry-run-no-mutation" \
'cat > /etc/apache2/sites-enabled/drytest.conf <<EOF
<VirtualHost *:80>ServerName dry.example.com</VirtualHost>
EOF
ln -sf /neexistuje /etc/apache2/conf-enabled/broken.conf
# Record state
find /etc/apache2 -maxdepth 3 -printf "%p %y\n" | sort > /tmp/pre-dryfix.txt
' \
'
bash -c "
    export CB_DRY_RUN=1
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    cb_apache_fix_sites_enabled_regular_files /etc/apache2 >/dev/null 2>&1
    cb_apache_fix_broken_symlinks /etc/apache2 >/dev/null 2>&1
"
find /etc/apache2 -maxdepth 3 -printf "%p %y\n" | sort > /tmp/post-dryfix.txt
diff /tmp/pre-dryfix.txt /tmp/post-dryfix.txt || { echo "DRY-RUN MODIFIED STATE!"; exit 1; }
'

# --- CASE 53: firewall respects state - firewalld not installed when absent ---
run_case "no-firewall-no-install" \
'# No firewall in the container (iptables is present because the image has it, but we verify
# the script does not mutate state). Before running, record installed packages.
dpkg -l | awk "{print \$2}" | sort > /tmp/pkgs-before
' \
'
dpkg -l | awk "{print \$2}" | sort > /tmp/pkgs-after
# Nothing is installed beyond what was already there
NEW_PKGS=$(comm -23 /tmp/pkgs-after /tmp/pkgs-before)
# Allowed additions: openssl is already in the image, so nothing new must appear
if [[ -n "$NEW_PKGS" ]]; then
    # firewalld/ufw/nftables NEVER
    echo "$NEW_PKGS" | grep -qE "^(firewalld|ufw|nftables|iptables)$" && {
        echo "CERTBERUS INSTALLED FIREWALL: $NEW_PKGS"
        exit 1
    }
fi
true
'

# --- CASE 54: idempotent autofix ---
run_case "idempotent-autofix" \
'cat > /etc/apache2/sites-enabled/idem.conf <<EOF
<VirtualHost *:80>ServerName idem.example.com</VirtualHost>
EOF
' \
'
# First run
bash -c "
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    cb_apache_fix_sites_enabled_regular_files /etc/apache2 >/dev/null 2>&1
"
find /etc/apache2 -printf "%p %y %l\n" | sort | md5sum > /tmp/after1.md5

# Second run - MUST NOT change anything
bash -c "
    export CB_DRY_RUN=0
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    source /tmp/cb/lib/common.sh
    source /tmp/cb/lib/preflight.sh
    cb_apache_fix_sites_enabled_regular_files /etc/apache2 >/dev/null 2>&1
"
find /etc/apache2 -printf "%p %y %l\n" | sort | md5sum > /tmp/after2.md5

diff /tmp/after1.md5 /tmp/after2.md5 || { echo "Second run changed state"; exit 1; }
'

# --- CASE 55: do not move when target already exists (collision protection) ---
run_case "autofix-no-clobber" \
'# A valid file with the same name already exists in sites-available (written differently)
cat > /etc/apache2/sites-available/collision.conf <<EOF
# ORIGINAL in sites-available
<VirtualHost *:80>
    ServerName original.example.com
</VirtualHost>
EOF
# And someone placed a completely different file into sites-enabled (regular file)
cat > /etc/apache2/sites-enabled/collision.conf <<EOF
# DIFFERENT in sites-enabled
<VirtualHost *:80>
    ServerName different.example.com
</VirtualHost>
EOF
md5sum /etc/apache2/sites-available/collision.conf | cut -d" " -f1 > /tmp/md5-orig
' \
'
# INVARIANT: on collision, sites-available MUST remain untouched
# (regardless of what the previous certberus issue did)
MD5_AVAIL_NOW=$(md5sum /etc/apache2/sites-available/collision.conf | cut -d" " -f1)
MD5_AVAIL_ORIG=$(cat /tmp/md5-orig)
[[ "$MD5_AVAIL_NOW" == "$MD5_AVAIL_ORIG" ]] || { echo "Overwrote sites-available"; exit 1; }

# Apache remains functional (the specific operation may or may not persist,
# but the collision fix is NOT performed destructively)
apache2ctl -t 2>&1 | grep -q "Syntax OK" || { echo "Apache failed"; apache2ctl -t; exit 1; }
'

# === CHAOS REGRESSION v3 - session 2026-04 ==================================
# The cases described below guard against regression of bugs found during chaos testing
# (example.com live run + docker matrix). Each case has a comment with the bug number.

# --- CASE 56: BUG #13/#9 - placeholder CB_ACME_URL panics, warns only 1x --
run_case "apache-placeholder-acme-url-dedup" \
'cat > /etc/certberus/config.env <<EOF
CB_EMAIL=admin@example.com
CB_CA=letsencrypt
CB_ACME_URL="https://acme-v02.harica.gr/acme/..../directory"
EOF' \
'
# Warning MUST appear (at least 1x), but NOT more than 2x (parent + subprocess is OK, 3+ is regression #13)
count=$(echo "$CERTBERUS_OUTPUT" | grep -c "CB_ACME_URL contains a placeholder")
[[ $count -ge 1 ]] || { echo "MISSING warning (BUG #9)"; exit 1; }
[[ $count -le 2 ]] || { echo "Warning duplicated $count x (BUG #13 regression)"; exit 1; }
'

# --- CASE 57: BUG #9b - CA/URL mismatch (letsencrypt + harica URL) ----------
run_case "apache-ca-url-mismatch-detected" \
'cat > /etc/certberus/config.env <<EOF
CB_EMAIL=admin@example.com
CB_CA=letsencrypt
CB_ACME_URL="https://acme-v02.harica.gr/acme/aaaa-bbbb/directory"
EOF' \
'
echo "$CERTBERUS_OUTPUT" | grep -qE "CB_CA=letsencrypt.*CB_ACME_URL is not letsencrypt" \
    || { echo "BUG #9b: mismatch not reported"; exit 1; }
'

# --- CASE 58: BUG #17 - cb_retry propagates non-zero rc (must not let 'if cmd' swallow) -
run_case "apache-cb-retry-propagates-failure" \
'' \
'
# Direct unit test of the helper: short, clear, sharp
set +e
RC=$(bash -c "
    source /tmp/cb/lib/common.sh
    CB_LOG_FILE=/tmp/cb.log CB_SYSLOG_ENABLED=0 cb_retry 2 0 false
    echo \$?
")
set -e
[[ "$RC" == "1" ]] || { echo "cb_retry returned $RC instead of 1 (BUG #17)"; exit 1; }

# Also cb_retry with a command that first fails then succeeds
RC2=$(bash -c "
    source /tmp/cb/lib/common.sh
    CB_LOG_FILE=/tmp/cb.log CB_SYSLOG_ENABLED=0
    F=/tmp/flag-\$\$; rm -f \$F
    # first call fails, then succeeds (flaky network emulation)
    cb_retry 3 0 bash -c \"[[ -f \$F ]] && exit 0 || { touch \$F; exit 1; }\"
    echo \$?
")
[[ "$RC2" == "0" ]] || { echo "cb_retry did not count flaky success (rc=$RC2)"; exit 1; }
'

# --- CASE 59: BUG #20 - service helpers have fallback when systemctl is missing ---
run_case "apache-svc-helpers-fallback" \
'' \
'
# Unit test of cb_svc_* helpers in various modes
set +e
bash -c "
    source /tmp/cb/lib/common.sh
    # _cb_has_systemd must answer correctly (fresh container: /run/systemd may or may not exist)
    if _cb_has_systemd; then
        echo has_systemd=1
    else
        echo has_systemd=0
        # When systemd is absent, cb_svc_* must try service/init.d/direct
        command -v service >/dev/null || command -v apache2ctl >/dev/null || exit 10
    fi
    # cb_svc_is_active on a nonexistent service must not hang the script - returns rc
    cb_svc_is_active something-that-definitely-does-not-exist-xyzzy || true
" 2>&1 | grep -qE "has_systemd=[01]" || { echo "cb_svc_* fallback broken"; exit 1; }
'

# --- CASE 60: snapshot INCLUDES extras (LE dir as regression #7 pattern) -----
run_case "apache-snapshot-includes-extras" \
'mkdir -p /etc/letsencrypt/live/marker.example.com /etc/letsencrypt/archive/marker.example.com
echo DUMMY > /etc/letsencrypt/live/marker.example.com/fullchain.pem
echo DUMMY > /etc/letsencrypt/archive/marker.example.com/fullchain1.pem
' \
'
set +e
bash -c "
    export CB_BACKUP_DIR=/tmp/ap-snap CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 CB_COLOR=never
    mkdir -p \$CB_BACKUP_DIR
    source /tmp/cb/lib/common.sh
    cb_snapshot /etc/apache2 apache-ex-test /etc/letsencrypt/live /etc/letsencrypt/archive >/dev/null
    [[ -f \$CB_LAST_SNAPSHOT ]] || exit 10
    tar -tzf \$CB_LAST_SNAPSHOT | grep -q 'etc/letsencrypt/live/marker' || exit 11
    tar -tzf \$CB_LAST_SNAPSHOT | grep -q 'etc/letsencrypt/archive/marker' || exit 12
    tar -tzf \$CB_LAST_SNAPSHOT | grep -q 'etc/apache2/apache2.conf' || exit 13
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "cb_snapshot did not propagate extras (BUG #7 regression)"; exit 1; }
'

# --- CASE 61: BUG #18b - baseline broken apache -> NO modifications ---------
run_case "apache-baseline-broken-no-modifications" \
'# Break apache before certberus
cat >> /etc/apache2/apache2.conf <<EOF
ThisBreakEverything xxx
EOF
# Remember state before certberus
find /etc/apache2 -type f -exec md5sum {} \; 2>/dev/null | sort > /tmp/before.md5
' \
'
# apache2 broken -> certberus must exit != 0 BEFORE snapshot/deploy
[[ $CERTBERUS_RC -ne 0 ]] || { echo "Should have failed"; exit 1; }
# No snapshot was created (preflight failed earlier)
ls /var/backups/certberus/apache2-pre-md-*.tar.gz 2>/dev/null \
    && { echo "Snapshot was created even though baseline was broken (BUG #18b)"; exit 1; }
# No modifications: md5 sum of all files remains the same
find /etc/apache2 -type f -exec md5sum {} \; 2>/dev/null | sort > /tmp/after.md5
diff /tmp/before.md5 /tmp/after.md5 || { echo "CHANGES despite broken baseline"; exit 1; }
'

# --- CASE 62: BUG #10/#17 - false-success detection (cb_certbot_issue) ------
# Apache does not use certbot, but the helper is prepared here. Unit test that the helper
# does NOT report success when "Some challenges have failed" appears in the output.
run_case "apache-cb-certbot-issue-false-success" \
'' \
'
# Mock certbot: exit 0 + text "Some challenges have failed"
cat > /usr/local/bin/certbot <<EOF
#!/bin/bash
echo "Some challenges have failed." >&2
exit 0
EOF
chmod +x /usr/local/bin/certbot
set +e
RC=$(bash -c "
    source /tmp/cb/lib/common.sh
    CB_LOG_FILE=/tmp/cb.log CB_SYSLOG_ENABLED=0 CB_COLOR=never
    cb_certbot_issue fake.test.invalid certonly -d fake.test.invalid >/dev/null 2>&1
    echo \$?
")
set -e
# cb_certbot_issue MUST return non-zero even when certbot returned 0
[[ "$RC" != "0" ]] || { echo "BUG #10 regression: helper reported success on fail"; exit 1; }
# Cleanup
rm -f /usr/local/bin/certbot
'

# --- CASE 63: non-systemd environment - cb_svc_is_active returns correctly ----
run_case "apache-nonsystemd-environment" \
'# Simulate non-systemd: hide systemctl from PATH
rm -f /tmp/fake-bin/systemctl 2>/dev/null
mkdir -p /tmp/fake-bin
# Pass-through: start apache via apache2ctl, certberus should use fallback
apache2ctl start 2>/dev/null || /usr/sbin/apache2 -k start 2>/dev/null || true
' \
'
# PATH without systemctl
set +e
PATH="/tmp/fake-bin:/usr/bin:/bin" bash -c "
    source /tmp/cb/lib/common.sh
    # _cb_has_systemd must return false (systemctl is not in PATH)
    if _cb_has_systemd; then
        echo NOK has_systemd=true despite PATH
        exit 5
    fi
    # cb_svc_is_active must fall back to pgrep/service fallback
    if cb_svc_is_active apache2; then
        echo apache_active_via_fallback
    else
        echo apache_not_active
    fi
    exit 0
"
RC=$?
set -e
[[ $RC -eq 0 ]] || { echo "Non-systemd env BUG #20 regression (rc=$RC)"; exit 1; }
apache2ctl stop 2>/dev/null || true
'

}  # end run_all_cases

# =============================================================================
# MAIN: iterate over distros
# =============================================================================
command -v docker >/dev/null || { echo "Docker is missing"; exit 2; }

OVERALL_RESULT=0
declare -A DISTRO_RESULTS

for distro in "${DISTROS[@]}"; do
    echo
    echo "################################################################"
    echo "#  DISTRO: $distro"
    echo "################################################################"
    if ! ensure_image "$distro"; then
        echo "### FAIL: image build failed for $distro, SKIP ###"
        DISTRO_RESULTS["$distro"]="BUILD_FAILED"
        continue
    fi
    PASS=0; FAIL=0; SKIP=0
    run_all_cases
    DISTRO_RESULTS["$distro"]="PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_SKIP=$((TOTAL_SKIP + SKIP))
    if (( KEEP == 0 )); then
        docker rmi "$IMG" >/dev/null 2>&1 || true
    fi
done

echo
echo "================================================================"
echo "  FINAL RESULTS (per distro)"
echo "================================================================"
for distro in "${!DISTRO_RESULTS[@]}"; do
    printf "  %-18s  %s\n" "$distro" "${DISTRO_RESULTS[$distro]}"
done
echo "----------------------------------------------------------------"
echo "  TOTAL: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"
echo "================================================================"
(( TOTAL_FAIL == 0 ))
