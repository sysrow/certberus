#!/bin/bash
# C-20: a `<VirtualHost _default_:443>` catch-all vhost is enabled with a
# stale self-signed cert (CN=legacy-host) referenced via SSLCertificateFile.
# Common pattern: admin set up a fallback TLS vhost years ago. certberus
# must not let this _default_ vhost shadow mod_md's named-vhost issuance,
# and must either neutralize the explicit cert paths or insert an MDomain
# block that takes precedence.

SCENARIO_ID="c-20"
SCENARIO_NAME="<VirtualHost _default_:443> catch-all with stale cert"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s120.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

openssl req -x509 -newkey rsa:2048 \
    -keyout /etc/ssl/private/legacy.key \
    -out    /etc/ssl/certs/legacy.crt \
    -days 30 -nodes -subj "/CN=legacy-host" 2>/dev/null

cat >/etc/apache2/sites-available/default-catch.conf <<EOF
<VirtualHost _default_:443>
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/legacy.crt
    SSLCertificateKeyFile /etc/ssl/private/legacy.key
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite default-ssl 000-default >/dev/null 2>&1 || true
a2ensite default-catch >/dev/null
apache2ctl -t
systemctl reload apache2 || systemctl restart apache2 || true
echo "scenario_seed: _default_:443 catch-all vhost with legacy self-signed cert enabled"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
