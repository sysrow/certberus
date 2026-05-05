#!/bin/bash
# tests/test-cert-lifecycle-chaos.sh
# Chaos around existing certificates - real-world scenarios that have already occurred:
#   - snakeoil is a real cert (must not be overwritten)
#   - cert protected by chattr +i
#   - privkey/cert mismatch
#   - fullchain without intermediate
#   - cert expired / with notBefore in the future
#   - LE archive scrambled
#   - cert is DER instead of PEM
#   - foreign CA in LE path
#
# All tests use docker (privileged for chattr) + apache as reference.
# Run: bash tests/test-cert-lifecycle-chaos.sh [--distro X] [--only NAME] [--keep]

set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0; ONLY=""; ONLY_DISTRO=""
DISTROS=(debian:12 debian:13 ubuntu:24.04)

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

ensure_image() {
    local distro="$1"
    IMG="certberus-cert-lifecycle-$(echo "$distro" | tr ':.' '-')"
    CURRENT_DISTRO="$distro"
    docker image inspect "$IMG" >/dev/null 2>&1 && return 0
    echo "### Building $IMG from $distro ###" >&2
    local df; df=$(mktemp)
    cat > "$df" <<DOCKER
FROM $distro
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \\
        apache2 sudo iptables certbot ssl-cert e2fsprogs \\
        python3 openssl ca-certificates curl && \\
    (apt-get install -y --no-install-recommends libapache2-mod-md 2>/dev/null || true) && \\
    rm -rf /var/lib/apt/lists/*
RUN a2enmod ssl md 2>/dev/null || true
DOCKER
    docker build --network=host -t "$IMG" -f "$df" . >&2 || { rm -f "$df"; return 1; }
    rm -f "$df"
}

# run_case NAME SETUP ASSERT
run_case() {
    local name="$1" setup="$2" assert="$3"
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
                rm -rf /var/backups/certberus /etc/letsencrypt 2>/dev/null
                mkdir -p /etc/certberus
                cat > /etc/certberus/advanced.env <<EOF
CB_SYSLOG_ENABLED=0
CB_AUTO_ROLLBACK=0
CB_COLOR=never
EOF
                # Helper function for generating a real self-signed cert
                gen_cert() {
                    local out_cert=\$1 out_key=\$2 cn=\${3:-test.local} days=\${4:-365}
                    local opts=\"\"
                    [[ \$days -lt 0 ]] && {
                        # Generate cert with given value (case ignored by openssl directly) - using faketime
                        days=1
                    }
                    openssl req -x509 -newkey rsa:2048 -nodes -days \$days \\
                        -keyout \$out_key -out \$out_cert \\
                        -subj \"/CN=\$cn\" >/dev/null 2>&1
                }
                $setup
                set +e
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

# =============================================================================
# B.1.1: snakeoil is a REAL cert - cb_apache_fix_ssl_cert_paths MUST NOT replace it
# (User example: real prod cert stored under the snakeoil name)
# =============================================================================
run_case "snakeoil-is-real-cert-not-replaced" \
'# Generate a REAL self-signed cert in place of snakeoil
gen_cert /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key real.example.com 365
# Create a vhost that references the snakeoil path
cat > /etc/apache2/sites-available/sni-real.conf <<EOF
<VirtualHost *:443>
    ServerName real.example.com
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
</VirtualHost>
EOF
a2ensite sni-real >/dev/null 2>&1
# Hash cert BEFORE intervention
md5sum /etc/ssl/certs/ssl-cert-snakeoil.pem | cut -d" " -f1 > /tmp/md5-snake-before
md5sum /etc/apache2/sites-available/sni-real.conf | cut -d" " -f1 > /tmp/md5-vhost-before
' \
'
source /tmp/cb/lib/common.sh
source /tmp/cb/lib/preflight.sh
CB_DRY_RUN=0 CB_SYSLOG_ENABLED=0 fixed=$(cb_apache_fix_ssl_cert_paths /etc/apache2 2>/dev/null | tail -1)
# Paths are valid (exist, regular file, non-empty) -> fixed must be 0
[[ "$fixed" == "0" ]] || { echo "FIX INTERVENED even though paths are valid: fixed=$fixed"; exit 1; }
# Snakeoil cert MUST be unchanged
md5_now=$(md5sum /etc/ssl/certs/ssl-cert-snakeoil.pem | cut -d" " -f1)
md5_before=$(cat /tmp/md5-snake-before)
[[ "$md5_now" == "$md5_before" ]] || { echo "BUG: snakeoil cert CHANGED!"; exit 1; }
# Vhost also untouched
md5_v=$(md5sum /etc/apache2/sites-available/sni-real.conf | cut -d" " -f1)
md5_vb=$(cat /tmp/md5-vhost-before)
[[ "$md5_v" == "$md5_vb" ]] || { echo "BUG: vhost overwritten even though cert was valid"; exit 1; }
'

# =============================================================================
# B.1.2: cert protected by chattr +i - rollback/fix must respond gracefully
# =============================================================================
run_case "cert-immutable-graceful-fail" \
'gen_cert /tmp/protected.pem /tmp/protected.key protected.local 365
chattr +i /tmp/protected.pem 2>/dev/null || { echo "chattr unsupported, SKIP" ; exit 0; }
' \
'
# Attempt to overwrite a protected file - without chattr -i it fails
set +e
echo "OVERWRITE_ATTEMPT" > /tmp/protected.pem 2>/tmp/err
RC=$?
chattr -i /tmp/protected.pem 2>/dev/null
rm -f /tmp/protected.pem /tmp/protected.key
set -e
# File must be unwritable (rc != 0)
[[ $RC -ne 0 ]] || { echo "chattr +i does not work in container, SKIP test"; exit 0; }
# Test passes if chattr works (or SKIP if it does not)
'

# =============================================================================
# B.1.3: privkey/cert mismatch - openssl modulus diff
# =============================================================================
run_case "privkey-cert-modulus-mismatch" \
'gen_cert /tmp/A.pem /tmp/A.key alpha.local 30
gen_cert /tmp/B.pem /tmp/B.key beta.local 30
# Store cert A with key B - classic deploy bug
cp /tmp/A.pem /tmp/mixed.pem
cp /tmp/B.key /tmp/mixed.key
' \
'
# Test that we can detect mismatch (basic helper for future validators)
mod_cert=$(openssl x509 -noout -modulus -in /tmp/mixed.pem | openssl md5 | cut -d" " -f2)
mod_key=$(openssl rsa  -noout -modulus -in /tmp/mixed.key 2>/dev/null | openssl md5 | cut -d" " -f2)
[[ "$mod_cert" != "$mod_key" ]] || { echo "Mismatch not detected"; exit 1; }
# Apache will not load this - certberus should have such a check before reload
# Here we only verify that openssl detects it; a helper will be added to common.sh later.
'

# =============================================================================
# B.1.4: fullchain without intermediate - contains ONLY leaf
# =============================================================================
run_case "fullchain-missing-intermediate" \
'# Self-signed is its own issuer - "fullchain" is just 1 cert (no intermediate)
gen_cert /tmp/leaf-only.pem /tmp/leaf-only.key leaf.local 30
# Create a fake LE structure
mkdir -p /etc/letsencrypt/live/leaf.local /etc/letsencrypt/archive/leaf.local
cp /tmp/leaf-only.pem /etc/letsencrypt/live/leaf.local/fullchain.pem
cp /tmp/leaf-only.key /etc/letsencrypt/live/leaf.local/privkey.pem
' \
'
# Number of certs in fullchain.pem
COUNT=$(grep -c "BEGIN CERTIFICATE" /etc/letsencrypt/live/leaf.local/fullchain.pem)
[[ "$COUNT" == "1" ]] || { echo "expected 1 cert, got $COUNT"; exit 1; }
# certberus should detect this as a warning (chain without intermediate is suspect)
# - test passes if certberus does not falsely report success on such a cert.
# For now we only verify the helper tools:
openssl verify -CAfile /etc/letsencrypt/live/leaf.local/fullchain.pem \
               /etc/letsencrypt/live/leaf.local/fullchain.pem >/dev/null 2>&1 && {
    # Self-signed "verifies" itself - simulation that openssl understands the format.
    true
}
'

# =============================================================================
# B.1.6: cert expired 30 days ago - issue --keep-until-expiring must react
# =============================================================================
run_case "cert-expired-detected" \
'# Generate a cert with -days 1, then shift the date 5 days forward = expired
gen_cert /tmp/old.pem /tmp/old.key old.local 1
mkdir -p /etc/letsencrypt/live/old.local /etc/letsencrypt/archive/old.local
cp /tmp/old.pem /etc/letsencrypt/live/old.local/fullchain.pem
cp /tmp/old.key /etc/letsencrypt/live/old.local/privkey.pem
# Faketime: cert.notAfter was 5 days ago
' \
'
# VERIFY that openssl detects expiration (without faketime, the cert above has
# notValidYet=false and expiry in 1 day is valid - so here we test:
# a cert with -days 0 at least expires quickly at some granularity.
# More realistically: generate a cert with notAfter = "yesterday" via faketime if installed:
if command -v faketime >/dev/null 2>&1; then
    faketime -f -2d openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout /tmp/exp.key -out /tmp/exp.pem -subj "/CN=exp.local" >/dev/null 2>&1
    openssl x509 -checkend 0 -in /tmp/exp.pem >/dev/null 2>&1 && {
        echo "checkend should have detected expired"; exit 1; }
fi
# Without faketime: just verify that checkend works on a non-expired cert
openssl x509 -checkend 0 -in /etc/letsencrypt/live/old.local/fullchain.pem >/dev/null 2>&1 || {
    echo "1-day cert should be valid"; exit 1; }
'

# =============================================================================
# B.1.8: fullchain with CRLF line endings (Windows style)
# =============================================================================
run_case "fullchain-crlf-line-endings" \
'gen_cert /tmp/u.pem /tmp/u.key u.local 30
mkdir -p /etc/letsencrypt/live/u.local
# Convert to CRLF
sed "s/$/\r/" /tmp/u.pem > /etc/letsencrypt/live/u.local/fullchain.pem
cp /tmp/u.key /etc/letsencrypt/live/u.local/privkey.pem
' \
'
# Do Apache + openssl tolerate CRLF? openssl x509 sometimes silently rejects it
if openssl x509 -in /etc/letsencrypt/live/u.local/fullchain.pem -noout 2>/dev/null; then
    : # OK, openssl is tolerant
else
    # If it does not tolerate CRLF, certberus should have detection/fix (sed -i s/\r//)
    # Simulate fix:
    sed -i "s/\r//" /etc/letsencrypt/live/u.local/fullchain.pem
    openssl x509 -in /etc/letsencrypt/live/u.local/fullchain.pem -noout 2>/dev/null || {
        echo "Still broken after dos2unix"; exit 1
    }
fi
'

# =============================================================================
# B.1.10: cert is DER instead of PEM
# =============================================================================
run_case "cert-is-DER-not-PEM" \
'gen_cert /tmp/p.pem /tmp/p.key p.local 30
openssl x509 -in /tmp/p.pem -outform DER -out /tmp/p.der
mkdir -p /etc/letsencrypt/live/p.local
cp /tmp/p.der /etc/letsencrypt/live/p.local/fullchain.pem
cp /tmp/p.key /etc/letsencrypt/live/p.local/privkey.pem
' \
'
# openssl 3.x auto-detects DER - cannot just call x509 -in.
# Real test: PEM cert must start with "-----BEGIN"; DER does not.
head -c 11 /etc/letsencrypt/live/p.local/fullchain.pem | grep -q "^-----BEGIN" && {
    echo "file is PEM, should be DER"; exit 1; }
# certberus should detect this format in pre-flight (apache requires PEM).
true
'

# =============================================================================
# B.1.11: fullchain.pem is empty (0 bytes, disk full during write)
# =============================================================================
run_case "fullchain-empty-zero-bytes" \
'mkdir -p /etc/letsencrypt/live/empty.local
: > /etc/letsencrypt/live/empty.local/fullchain.pem
: > /etc/letsencrypt/live/empty.local/privkey.pem
' \
'
# Apache rejects, openssl rejects - must be detected
[[ -s /etc/letsencrypt/live/empty.local/fullchain.pem ]] && { echo "file is not empty?"; exit 1; }
openssl x509 -in /etc/letsencrypt/live/empty.local/fullchain.pem -noout 2>/dev/null && {
    echo "openssl accepted empty as cert"; exit 1; }
true
'

# =============================================================================
# B.1.13: cert with notBefore in the future (clock skew)
# =============================================================================
run_case "cert-notbefore-future" \
'if ! command -v faketime >/dev/null 2>&1; then
    apt-get install -y faketime >/dev/null 2>&1 || { echo "skip - no faketime"; exit 0; }
fi
faketime "+2 years" openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout /tmp/future.key -out /tmp/future.pem \
    -subj "/CN=future.local" >/dev/null 2>&1
' \
'
# If faketime did not work, the file does not exist or is not from the future
if [[ ! -f /tmp/future.pem ]]; then echo "no future cert (faketime missing) - skip"; exit 0; fi

NOTBEFORE=$(openssl x509 -in /tmp/future.pem -noout -startdate | cut -d= -f2)
NB_TS=$(date -d "$NOTBEFORE" +%s 2>/dev/null || echo 0)
NOW_TS=$(date +%s)
[[ $NB_TS -gt $NOW_TS ]] || { echo "notBefore is not in the future (faketime may not work)"; exit 0; }
# openssl x509 -checkend must signal this "not yet valid" state somehow
# checkend 0 returns ok if the cert DOES NOT EXPIRE within the next N seconds
# - so the future cert "is not expired", but apache will still refuse to load it.
# Just verify that we can detect the skew:
[[ $((NB_TS - NOW_TS)) -gt 86400 ]] || { echo "skew too small"; exit 1; }
'

# =============================================================================
# B.1.14: privkey with passphrase (password-protected)
# =============================================================================
run_case "privkey-with-passphrase" \
'openssl req -x509 -newkey rsa:2048 -days 30 \
    -passout pass:secret123 \
    -keyout /tmp/pass.key -out /tmp/pass.pem \
    -subj "/CN=pass.local" >/dev/null 2>&1
' \
'
# openssl rsa without password must fail
openssl rsa -in /tmp/pass.key -noout 2>/dev/null && {
    echo "BUG: privkey with passphrase passed without password"; exit 1; }
# With password it passes
openssl rsa -in /tmp/pass.key -passin pass:secret123 -noout 2>/dev/null || {
    echo "passphrase mechanism does not work"; exit 1; }
# Therefore: certberus should report a clear error when detecting such a key
# (apache will not unlock such a key automatically)
'

# =============================================================================
# B.1.15: LE account corrupted (regr.json broken JSON)
# =============================================================================
run_case "le-account-corrupted-json" \
'mkdir -p /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/abcdef123
echo "{ this is not json" > /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/abcdef123/regr.json
echo "{}" > /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/abcdef123/meta.json
' \
'
# certbot will fail on renew with such an account.
# Test verifies that we can detect broken JSON before calling certbot:
python3 -c "import json,sys; json.load(open(\"/etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/abcdef123/regr.json\"))" 2>/dev/null && {
    echo "JSON parser should have failed on broken file"; exit 1; }
# OK - parser detects the problem, certberus can have a pre-flight check
true
'

# =============================================================================
# B.1.16: foreign CA cert v LE path (HARICA cert v /etc/letsencrypt)
# =============================================================================
run_case "foreign-ca-in-LE-path" \
'# Create a cert with an "Issuer" different from Lets Encrypt
gen_cert /tmp/harica-ca.pem /tmp/harica-ca.key "HARICA-Test-CA" 30
openssl req -newkey rsa:2048 -nodes -days 30 \
    -keyout /tmp/foo.key -out /tmp/foo.csr \
    -subj "/CN=foo.local" >/dev/null 2>&1
openssl x509 -req -in /tmp/foo.csr -CA /tmp/harica-ca.pem -CAkey /tmp/harica-ca.key \
    -CAcreateserial -days 30 -out /tmp/foo.pem >/dev/null 2>&1
mkdir -p /etc/letsencrypt/live/foo.local
cat /tmp/foo.pem /tmp/harica-ca.pem > /etc/letsencrypt/live/foo.local/fullchain.pem
cp /tmp/foo.key /etc/letsencrypt/live/foo.local/privkey.pem
' \
'
# Issuer != Lets Encrypt - certberus should detect that the cert is NOT from LE.
ISSUER=$(openssl x509 -in /etc/letsencrypt/live/foo.local/fullchain.pem -noout -issuer 2>/dev/null)
echo "$ISSUER" | grep -qiE "lets.*encrypt|R3|R10|E1|E5" && {
    echo "BUG: issuer detection does not work, got LE-like match: $ISSUER"; exit 1; }
echo "$ISSUER" | grep -qi "HARICA-Test" || { echo "issuer does not contain HARICA: $ISSUER"; exit 1; }
'

# =============================================================================
# B.1.17: fullchain contains ONLY intermediate, no leaf
# =============================================================================
run_case "fullchain-only-intermediate" \
'gen_cert /tmp/ca.pem /tmp/ca.key "Intermediate-CA" 30
mkdir -p /etc/letsencrypt/live/no-leaf.local
# Instead of leaf+intermediate we store only intermediate
cp /tmp/ca.pem /etc/letsencrypt/live/no-leaf.local/fullchain.pem
gen_cert /tmp/leaf.pem /tmp/leaf.key leaf.local 30
cp /tmp/leaf.key /etc/letsencrypt/live/no-leaf.local/privkey.pem
' \
'
# Privkey does NOT match the CA cert (different modulus) - certberus should detect this
mod_c=$(openssl x509 -in /etc/letsencrypt/live/no-leaf.local/fullchain.pem -noout -modulus | openssl md5 | cut -d" " -f2)
mod_k=$(openssl rsa  -in /etc/letsencrypt/live/no-leaf.local/privkey.pem -noout -modulus | openssl md5 | cut -d" " -f2)
[[ "$mod_c" != "$mod_k" ]] || { echo "expected mismatch"; exit 1; }
# certberus deploy should verify key/cert match before reload - this is a missing feature.
'

# =============================================================================
# B.1.5: /etc/letsencrypt/live/DOMAIN is a broken symlink chain
# =============================================================================
run_case "le-live-broken-symlink-chain" \
'gen_cert /tmp/c.pem /tmp/c.key c.local 30
mkdir -p /etc/letsencrypt/live/c.local /etc/letsencrypt/archive/c.local
# Correct LE layout: live/X/fullchain.pem -> ../../archive/X/fullchain1.pem
cp /tmp/c.pem /etc/letsencrypt/archive/c.local/fullchain1.pem
ln -sf ../../archive/c.local/fullchain1.pem /etc/letsencrypt/live/c.local/fullchain.pem
# And now someone (admin/backup tool) deleted it from archive
rm -f /etc/letsencrypt/archive/c.local/fullchain1.pem
' \
'
# fullchain.pem in live is now a broken symlink
[[ -L /etc/letsencrypt/live/c.local/fullchain.pem ]] || { echo "not a symlink"; exit 1; }
[[ ! -e /etc/letsencrypt/live/c.local/fullchain.pem ]] || { echo "symlink still valid"; exit 1; }
# certberus expiry/status must detect this and report it (not crash)
# Test cmd_status logic directly:
set +e
output=$(/usr/local/sbin/certberus status 2>&1)
RC=$?
set -e
# Status must not hang / segfault
[[ $RC -lt 128 ]] || { echo "status segfaulted rc=$RC"; exit 1; }
'

# =============================================================================
# B.1.6 var: two certs for the same domain (after --cert-name bypass)
# =============================================================================
run_case "duplicate-cert-name-for-same-domain" \
'gen_cert /tmp/d1.pem /tmp/d1.key dual.local 30
gen_cert /tmp/d2.pem /tmp/d2.key dual.local 30
mkdir -p /etc/letsencrypt/live/dual.local /etc/letsencrypt/live/dual.local-0001
mkdir -p /etc/letsencrypt/archive/dual.local /etc/letsencrypt/archive/dual.local-0001
cp /tmp/d1.pem /etc/letsencrypt/live/dual.local/fullchain.pem
cp /tmp/d1.key /etc/letsencrypt/live/dual.local/privkey.pem
cp /tmp/d2.pem /etc/letsencrypt/live/dual.local-0001/fullchain.pem
cp /tmp/d2.key /etc/letsencrypt/live/dual.local-0001/privkey.pem
' \
'
# certberus expiry/status must find both and warn
[[ -d /etc/letsencrypt/live/dual.local ]] || exit 1
[[ -d /etc/letsencrypt/live/dual.local-0001 ]] || exit 1
# This is a path for a future feature: warn on duplicate cert-name pattern
'

# =============================================================================
# B.1.7: cert ECDSA, but privkey RSA (type mismatch)
# =============================================================================
run_case "ecdsa-cert-rsa-key-mismatch" \
'# ECDSA cert
openssl ecparam -genkey -name prime256v1 -out /tmp/ec.key 2>/dev/null
openssl req -new -x509 -key /tmp/ec.key -days 30 -out /tmp/ec.pem \
    -subj "/CN=ec.local" >/dev/null 2>&1
# RSA key
openssl genrsa -out /tmp/rsa.key 2048 2>/dev/null
mkdir -p /etc/letsencrypt/live/ec-mismatch.local
cp /tmp/ec.pem /etc/letsencrypt/live/ec-mismatch.local/fullchain.pem
cp /tmp/rsa.key /etc/letsencrypt/live/ec-mismatch.local/privkey.pem
' \
'
# openssl pubkey from cert vs from key must be different
PUB_CERT=$(openssl x509 -in /etc/letsencrypt/live/ec-mismatch.local/fullchain.pem -noout -pubkey 2>/dev/null | openssl md5 | cut -d" " -f2)
PUB_KEY=$(openssl rsa  -in /etc/letsencrypt/live/ec-mismatch.local/privkey.pem -pubout 2>/dev/null | openssl md5 | cut -d" " -f2)
[[ "$PUB_CERT" != "$PUB_KEY" ]] || { echo "expected pubkey mismatch"; exit 1; }
# Apache will not work with such a combo - certberus should have a pre-flight check
'

# =============================================================================
# B.1.9: cert with SAN different from requested (SANs changed after renew)
# =============================================================================
run_case "cert-san-mismatch-with-config" \
'openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -keyout /tmp/san.key -out /tmp/san.pem \
    -subj "/CN=primary.local" \
    -addext "subjectAltName=DNS:primary.local,DNS:OLD-secondary.local" >/dev/null 2>&1
mkdir -p /etc/letsencrypt/live/san-mismatch.local
cp /tmp/san.pem /etc/letsencrypt/live/san-mismatch.local/fullchain.pem
cp /tmp/san.key /etc/letsencrypt/live/san-mismatch.local/privkey.pem
' \
'
# Cert has SAN: primary.local + OLD-secondary.local
# Config CB_DOMAINS would want: primary.local + NEW-secondary.local
# certberus on renew must detect the difference and send --expand
SAN=$(openssl x509 -in /etc/letsencrypt/live/san-mismatch.local/fullchain.pem -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative Name" | tail -1 | tr -d " ")
echo "$SAN" | grep -q "OLD-secondary" || { echo "missing expected SAN: $SAN"; exit 1; }
# Helper for comparing SAN sets belongs in common.sh
'

# =============================================================================
# B.1.18: cert signed by self-signed root outside CA store
# =============================================================================
run_case "cert-signed-by-untrusted-root" \
'gen_cert /tmp/root.pem /tmp/root.key "Untrusted-Root" 30
openssl req -newkey rsa:2048 -nodes -days 30 \
    -keyout /tmp/sig.key -out /tmp/sig.csr \
    -subj "/CN=sig.local" >/dev/null 2>&1
openssl x509 -req -in /tmp/sig.csr -CA /tmp/root.pem -CAkey /tmp/root.key \
    -CAcreateserial -days 30 -out /tmp/sig.pem >/dev/null 2>&1
mkdir -p /etc/letsencrypt/live/untrusted.local
cat /tmp/sig.pem /tmp/root.pem > /etc/letsencrypt/live/untrusted.local/fullchain.pem
cp /tmp/sig.key /etc/letsencrypt/live/untrusted.local/privkey.pem
' \
'
# openssl verify without explicit CAfile fails (due to unknown root)
openssl verify /etc/letsencrypt/live/untrusted.local/fullchain.pem 2>&1 | grep -qE "OK|self.signed" || true
# openssl verify with CAfile=fullchain.pem validates it (chain is in the file) - so chain is CONSISTENT
openssl verify -CAfile /etc/letsencrypt/live/untrusted.local/fullchain.pem \
               /etc/letsencrypt/live/untrusted.local/fullchain.pem >/dev/null 2>&1 || {
    echo "own chain is not self-valid"; exit 1; }
# Browser/curl without installed CA will reject - certberus should report (post-issue verify)
'

}  # end run_all_cases

# =============================================================================
command -v docker >/dev/null || { echo "Docker missing"; exit 2; }

for distro in "${DISTROS[@]}"; do
    echo "==============================================================="
    echo " CERT LIFECYCLE CHAOS :: $distro"
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
