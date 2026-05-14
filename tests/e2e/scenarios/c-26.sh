#!/bin/bash
# C-26: reverse-proxy vhost on :443 fronting a backend on 127.0.0.1:3000 with
# ProxyPreserveHost / ProxyPass / ProxyPassReverse. Self-signed cert pinned
# via SSLCertificateFile. Replicates the classic "Apache in front of a Node
# app" pattern. After certberus install, the proxy directives MUST still be
# present (we want to make sure no over-eager sed pass nukes them) and the
# cert MUST be the new mod_md-issued one rather than the legacy self-signed.

SCENARIO_ID="c-26"
SCENARIO_NAME="Apache reverse-proxy vhost (ProxyPass) with self-signed cert"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s126.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl proxy proxy_http >/dev/null

openssl req -x509 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$FQDN.key" \
    -out    "/etc/ssl/certs/$FQDN.crt" \
    -days 30 -nodes -subj "/CN=$FQDN" 2>/dev/null

cat >/etc/apache2/sites-available/rproxy.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/$FQDN.crt
    SSLCertificateKeyFile /etc/ssl/private/$FQDN.key
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:3000/
    ProxyPassReverse / http://127.0.0.1:3000/
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite rproxy >/dev/null
apache2ctl -t
systemctl reload apache2 || systemctl restart apache2
echo "scenario_seed: reverse-proxy vhost enabled, self-signed cert in /etc/ssl"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

# Make sure certberus didn't strip the ProxyPass/ProxyPassReverse lines while
# rewriting the vhost. We don't care which file holds them — just that they
# are still active somewhere under /etc/apache2/sites-enabled/.
scenario_post_verify() {
    local proxypass_count proxyreverse_count
    proxypass_count=$(box_ssh "$BOX" \
        'grep -rhsE "^[[:space:]]*ProxyPass[[:space:]]+/[[:space:]]+http://127\.0\.0\.1:3000/" /etc/apache2/sites-enabled/ 2>/dev/null | wc -l')
    proxyreverse_count=$(box_ssh "$BOX" \
        'grep -rhsE "^[[:space:]]*ProxyPassReverse[[:space:]]+/[[:space:]]+http://127\.0\.0\.1:3000/" /etc/apache2/sites-enabled/ 2>/dev/null | wc -l')

    echo "scenario_post_verify: ProxyPass directives found = $proxypass_count"
    echo "scenario_post_verify: ProxyPassReverse directives found = $proxyreverse_count"

    if [[ "${proxypass_count:-0}" -lt 1 || "${proxyreverse_count:-0}" -lt 1 ]]; then
        echo "scenario_post_verify: FAIL - certberus removed reverse-proxy directives from the vhost"
        return 1
    fi
    echo "scenario_post_verify: OK - reverse-proxy directives preserved"
}
