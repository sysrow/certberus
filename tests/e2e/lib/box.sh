#!/bin/bash
# tests/e2e/lib/box.sh - SSH helpers and box lifecycle for e2e chaos tests.
# Sourced by run-on-box.sh and individual scenario scripts.

[[ -n "${_CB_E2E_BOX_LOADED:-}" ]] && return 0
_CB_E2E_BOX_LOADED=1

# Box registry. Driven entirely by env so no operator-specific hostnames,
# IPs or DNS zones are committed to the repository. To run the matrix:
#
#   export CB_E2E_DEB12_IP=1.2.3.4
#   export CB_E2E_DEB12_WILDCARD=example12.test
#   export CB_E2E_DEB13_IP=5.6.7.8
#   export CB_E2E_DEB13_WILDCARD=example13.test
#   export CB_E2E_EMAIL=acme-staging@example.test
#   bash tests/e2e/run-matrix.sh
#
# Each wildcard must be the DNS apex below which `*.WILDCARD` resolves to
# the box IP — scenarios use FQDNs of the form `s<N>.<WILDCARD>`.
declare -gA BOX_IP=(
    [deb12]="${CB_E2E_DEB12_IP:-}"
    [deb13]="${CB_E2E_DEB13_IP:-}"
)
declare -gA BOX_FQDN=(
    [deb12]="${CB_E2E_DEB12_WILDCARD:-}"
    [deb13]="${CB_E2E_DEB13_WILDCARD:-}"
)
declare -gA BOX_WILDCARD=(
    [deb12]="${CB_E2E_DEB12_WILDCARD:-}"
    [deb13]="${CB_E2E_DEB13_WILDCARD:-}"
)
# Contact e-mail used in `certbot --email` / `--email` flags by scenarios.
CB_E2E_EMAIL="${CB_E2E_EMAIL:-}"
# Fail fast if any required value is missing — keeps the matrix from running
# against an empty hostname (which would otherwise fail much later with a
# confusing "Could not resolve" inside one of the scenarios).
for _k in deb12 deb13; do
    if [[ -z "${BOX_IP[$_k]:-}" || -z "${BOX_WILDCARD[$_k]:-}" ]]; then
        echo "box.sh: missing CB_E2E_${_k^^}_IP or CB_E2E_${_k^^}_WILDCARD env" >&2
        echo "        export them before running run-matrix.sh / run-on-box.sh." >&2
        return 1 2>/dev/null || exit 1
    fi
done
[[ -n "$CB_E2E_EMAIL" ]] || { echo "box.sh: missing CB_E2E_EMAIL env" >&2; return 1 2>/dev/null || exit 1; }
unset _k

# box_ssh BOX CMD [ARGS...] — run CMD over SSH as root.
# CMD is a single string (heredocs encouraged).
box_ssh() {
    local box="$1"; shift
    local ip="${BOX_IP[$box]:-}" alias="${BOX_FQDN[$box]:-}"
    [[ -z "$ip" ]] && { echo "box_ssh: unknown box: $box" >&2; return 2; }
    ssh -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o HostKeyAlias="$alias" -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        "root@$ip" "$@"
}

# box_scp BOX SRC DST — copy SRC (local) to DST (on box) as root.
box_scp() {
    local box="$1" src="$2" dst="$3"
    local ip="${BOX_IP[$box]:-}" alias="${BOX_FQDN[$box]:-}"
    [[ -z "$ip" ]] && { echo "box_scp: unknown box: $box" >&2; return 2; }
    scp -q -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o HostKeyAlias="$alias" -o ConnectTimeout=10 \
        "$src" "root@$ip:$dst"
}

# box_wait_ssh BOX [TIMEOUT_S] — block until SSH on BOX answers.
box_wait_ssh() {
    local box="$1" timeout="${2:-180}" deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if box_ssh "$box" 'echo ok' >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    echo "box_wait_ssh: $box still unreachable after ${timeout}s" >&2
    return 1
}

# box_reset BOX — purge every webserver/cert manager + state we touch.
# Idempotent. Leaves the box at "clean Debian + iptables open" baseline.
box_reset() {
    local box="$1"
    box_ssh "$box" 'bash -s' <<'REMOTE'
set -u
export DEBIAN_FRONTEND=noninteractive

# Stop anything that might hold ports 80/443 or interfere
systemctl stop apache2 nginx 'tomcat*' 'jetty*' caddy firewalld 2>/dev/null
systemctl disable apache2 nginx 'tomcat*' 'jetty*' caddy firewalld 2>/dev/null

# Unmask units that earlier scenarios may have masked (notably c-19 / any
# scenario that exercises `systemctl mask`). Masking is a symlink to
# /dev/null in /etc/systemd/system that survives `apt-get purge` of the
# owning package, so the next scenario installing apache2 inherits a
# masked unit and fails with "Unit apache2.service is masked." This is
# pure harness hygiene — the realistic "admin masked the unit" case is
# covered by certberus's own preflight, not by trying to recover here.
systemctl unmask apache2 nginx 'tomcat*' 'jetty*' caddy 2>/dev/null

# Purge packages. Listing the unusual ones explicitly avoids accidentally
# nuking parts of the base system. Ignored failures are fine.
apt-get -y -qq purge \
    apache2 apache2-bin apache2-data apache2-utils \
    libapache2-mod-md libapache2-mod-security2 libapache2-mod-php \
    nginx nginx-core nginx-common nginx-full \
    tomcat9 tomcat9-common tomcat10 tomcat10-common \
    jetty9 jetty9-common jetty12 jetty12-common \
    caddy \
    certbot python3-certbot python3-certbot-apache python3-certbot-nginx \
    certberus \
    ufw firewalld 2>/dev/null

apt-get -y -qq autoremove --purge 2>/dev/null

# Belt-and-suspenders: dpkg-level purge in case apt-get purge skipped any.
# Without this, a re-installed package can hit the dpkg rule
# "user deleted this conffile, don't restore" and silently come back broken.
for p in apache2 apache2-bin apache2-data apache2-utils libapache2-mod-md \
         nginx nginx-core nginx-common nginx-full \
         tomcat9 tomcat9-common tomcat10 tomcat10-common \
         jetty9 jetty12 caddy certbot ufw firewalld certberus; do
    dpkg --purge "$p" 2>/dev/null
done

# Wipe runtime state (NOT package conffile directories — purge handled those).
# Touching /etc/apache2, /etc/nginx, /etc/tomcat*, /etc/jetty*, /etc/caddy
# directly via rm -rf confuses dpkg conffile tracking and breaks future
# apt install of the same package on the same box.
# We DO rm /var/log/apache2 and /var/log/nginx — this is a realistic stale
# state (admins do `rm -rf /var/log/apache2` to free disk space), and the
# matrix is supposed to find places where certberus does not auto-heal it.
rm -rf \
    /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt \
    /etc/certberus /var/log/certberus /var/backups/certberus /opt/certberus \
    /var/lib/apache2 /var/lib/nginx /var/log/apache2 /var/log/nginx \
    /etc/systemd/system/certberus*.timer /etc/systemd/system/certberus*.service \
    /etc/cron.d/certberus 2>/dev/null

# Re-create empty webserver log dirs. Without this the next
# `apt-get install apache2` from a scenario seed fails because the apache2
# postinst calls `touch /var/log/apache2/error.log` without `mkdir -p` first.
# This is harness hygiene between test runs — the realistic "admin nuked the
# log dir" scenario is covered by a dedicated scenario that exercises
# certberus's own auto-heal.
mkdir -p /var/log/apache2 /var/log/nginx
chown root:adm /var/log/apache2 2>/dev/null
chown www-data:adm /var/log/nginx 2>/dev/null
chmod 750 /var/log/apache2 /var/log/nginx 2>/dev/null

# Reset netfilter: allow everything (the test harness or scenario will
# re-tighten as needed).
iptables -F 2>/dev/null
iptables -X 2>/dev/null
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
nft flush ruleset 2>/dev/null || true

# Reset locale/time hygiene (some scenarios skew the clock — undo).
timedatectl set-ntp true 2>/dev/null || true

# Update apt index once so per-scenario installs are fast.
apt-get -qq update 2>/dev/null

systemctl daemon-reload
echo "RESET_OK on $(hostname) $(lsb_release -ds 2>/dev/null)"
REMOTE
}

# box_install_certberus_deb BOX LOCAL_DEB_PATH
box_install_certberus_deb() {
    local box="$1" local_deb="$2"
    [[ -f "$local_deb" ]] || { echo "box_install_certberus_deb: no such file: $local_deb" >&2; return 2; }
    box_scp "$box" "$local_deb" /root/certberus.deb || return 1
    box_ssh "$box" 'dpkg -i /root/certberus.deb >/tmp/dpkg.log 2>&1 \
        || apt-get -y -f install 2>>/tmp/dpkg.log \
        && certberus --version 2>/dev/null | head -1'
}

# box_dump_diagnostics BOX FQDN OUTDIR
#   Pull artefacts that help diagnose a failed scenario.
box_dump_diagnostics() {
    local box="$1" fqdn="$2" outdir="$3"
    mkdir -p "$outdir"
    box_ssh "$box" '
        set +e
        echo "--- certberus.log ---";        tail -300 /var/log/certberus/certberus.log 2>/dev/null
        echo "--- apache2 error.log ---";    tail -200 /var/log/apache2/error.log 2>/dev/null
        echo "--- nginx error.log ---";      tail -200 /var/log/nginx/error.log 2>/dev/null
        echo "--- letsencrypt log ---";      tail -200 /var/log/letsencrypt/letsencrypt.log 2>/dev/null
        echo "--- mod_md store tree ---";    find /etc/apache2/md -maxdepth 4 -print 2>/dev/null
        echo "--- mod_md md.json (any) ---"; find /etc/apache2/md -name md.json -exec head -200 {} + 2>/dev/null
        echo "--- /etc/apache2/sites-enabled/ ---"; ls -la /etc/apache2/sites-enabled/ 2>/dev/null
        echo "--- enabled vhost contents ---";    cat /etc/apache2/sites-enabled/*.conf 2>/dev/null
        echo "--- /etc/apache2/conf-enabled/ ---"; ls -la /etc/apache2/conf-enabled/ 2>/dev/null
        echo "--- certberus-md.conf ---"; cat /etc/apache2/conf-enabled/certberus-md.conf 2>/dev/null
        echo "--- certificates ---";       certbot certificates 2>/dev/null
        echo "--- iptables ---";           iptables -L -n -v 2>/dev/null
        echo "--- date ---";               date -u
    ' >"$outdir/$box-$fqdn.diag.txt" 2>&1
}

# verify_cert FQDN [EXPECTED_ISSUER_REGEX]
#   Returns 0 if openssl s_client returns a cert chain whose leaf CN/SAN
#   matches FQDN and whose issuer matches EXPECTED_ISSUER_REGEX
#   (default: "(STAGING )?Let.s Encrypt").
verify_cert() {
    local fqdn="$1"
    local want_issuer="${2:-(STAGING )?Let.s Encrypt}"
    local out leaf issuer subject sans
    out=$(timeout 20 openssl s_client -servername "$fqdn" -connect "$fqdn:443" \
            -showcerts </dev/null 2>/dev/null | \
            openssl x509 -noout -issuer -subject -text 2>/dev/null) || return 1
    issuer=$(grep -E '^issuer=' <<<"$out" | head -1)
    subject=$(grep -E '^subject=' <<<"$out" | head -1)
    sans=$(grep -A1 'Subject Alternative Name:' <<<"$out" | tail -1 | tr -d ' ' | tr ',' '\n')

    if ! grep -Eq "$want_issuer" <<<"$issuer"; then
        echo "verify_cert: issuer mismatch (got: $issuer; want regex: $want_issuer)" >&2
        return 1
    fi
    # CN or any SAN must equal the FQDN
    if grep -Eq "(CN ?= ?$fqdn\b)" <<<"$subject" || grep -Fxq "DNS:$fqdn" <<<"$sans"; then
        echo "verify_cert: OK ($issuer ; $subject)"
        return 0
    fi
    echo "verify_cert: CN/SAN mismatch (subject=$subject ; sans=$sans ; want=$fqdn)" >&2
    return 1
}

# wait_for_cert FQDN TIMEOUT_S — poll openssl s_client up to TIMEOUT_S seconds
# for the cert to flip to the desired issuer. Used after mod_md async issuance.
wait_for_cert() {
    local fqdn="$1" timeout="${2:-180}" want_issuer="${3:-(STAGING )?Let.s Encrypt}"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if verify_cert "$fqdn" "$want_issuer" >/dev/null 2>&1; then
            verify_cert "$fqdn" "$want_issuer"
            return 0
        fi
        sleep 5
    done
    echo "wait_for_cert: timed out after ${timeout}s for $fqdn (want issuer: $want_issuer)" >&2
    verify_cert "$fqdn" "$want_issuer" || true
    return 1
}
