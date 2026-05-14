#!/bin/bash
# C-25: production-style hardened vhost. ServerTokens Prod, ServerSignature
# Off, TraceEnable Off, FileETag None, plus the full battery of security
# headers (HSTS, X-Frame-Options, CSP-ish, Permissions-Policy). Vhost
# references a self-signed cert via SSLCertificateFile. Replicates the
# common "I followed Mozilla's SSL guide" setup. certberus must not regress
# those headers and must transparently take over the cert paths.

SCENARIO_ID="c-25"
SCENARIO_NAME="Hardened production vhost with self-signed cert + full security headers"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s125.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl headers rewrite >/dev/null

openssl req -x509 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$FQDN.key" \
    -out    "/etc/ssl/certs/$FQDN.crt" \
    -days 30 -nodes -subj "/CN=$FQDN" 2>/dev/null

cat >/etc/apache2/conf-available/zz-hardening.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
EOF
a2enconf zz-hardening >/dev/null

cat >/etc/apache2/sites-available/hardened.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLHonorCipherOrder on
    SSLCertificateFile    /etc/ssl/certs/$FQDN.crt
    SSLCertificateKeyFile /etc/ssl/private/$FQDN.key
    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy no-referrer-when-downgrade
    Header always set Permissions-Policy "geolocation=()"
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite hardened >/dev/null
apache2ctl -t
systemctl reload apache2 || systemctl restart apache2
echo "scenario_seed: hardened vhost + zz-hardening.conf in place, self-signed cert installed"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
