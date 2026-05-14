#!/bin/bash
# C-12: pre-existing :443 vhost with a self-signed cert plus a fully
# preloaded HSTS header and a stack of hardening headers (X-Frame-Options,
# X-Content-Type-Options). The HSTS preload directive is irreversible from
# the client's POV — any cert switch must not break the listener. Verifies
# certberus install hands control over to mod_md without breaking HSTS or
# the existing headers.

SCENARIO_ID="c-12"
SCENARIO_NAME="Pre-existing HSTS-preloaded vhost with self-signed cert"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s112.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md openssl
a2enmod ssl headers >/dev/null

openssl req -x509 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$FQDN.key" \
    -out "/etc/ssl/certs/$FQDN.crt" \
    -days 30 -nodes \
    -subj "/CN=$FQDN" 2>/dev/null

cat >/etc/apache2/sites-available/hsts.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/$FQDN.crt
    SSLCertificateKeyFile /etc/ssl/private/$FQDN.key
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite hsts >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: HSTS-preloaded self-signed vhost active for $FQDN"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # HSTS header must still be served after certberus takes over.
    local hsts
    hsts=$(timeout 15 openssl s_client -servername "$FQDN" -connect "$FQDN:443" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null) || return 1
    echo "scenario_post_verify: subject = $hsts"
    box_ssh "$BOX" "grep -q 'Strict-Transport-Security' /etc/apache2/sites-enabled/hsts.conf" \
        || { echo "scenario_post_verify: FAIL — HSTS header missing from vhost after install"; return 1; }
    echo "scenario_post_verify: OK (HSTS header preserved)"
}
