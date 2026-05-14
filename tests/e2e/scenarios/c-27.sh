#!/bin/bash
# C-27: Apache with mod_http2 enabled plus an existing self-signed cert in a
# user-managed :443 vhost that declares Protocols h2 http/1.1. Mirrors an
# admin who turned on HTTP/2 years ago, dropped in a self-signed placeholder
# and then walked away. After certberus install we must still see the
# http2_module loaded, mod_md must have issued a real cert, and ALPN should
# not be broken by us stripping the wrong directives.

SCENARIO_ID="c-27"
SCENARIO_NAME="Apache + mod_http2 + self-signed placeholder cert"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s127.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl http2 headers >/dev/null

mkdir -p /etc/ssl/private
openssl req -x509 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$FQDN.key" \
    -out "/etc/ssl/certs/$FQDN.crt" \
    -days 30 -nodes -subj "/CN=$FQDN" 2>/dev/null
chmod 600 "/etc/ssl/private/$FQDN.key"

cat >/etc/apache2/sites-available/h2.conf <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
</VirtualHost>

<VirtualHost *:443>
    ServerName $FQDN
    Protocols h2 http/1.1
    SSLEngine on
    SSLCertificateFile      /etc/ssl/certs/$FQDN.crt
    SSLCertificateKeyFile   /etc/ssl/private/$FQDN.key
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite h2 >/dev/null
apache2ctl -t
systemctl reload apache2 || systemctl restart apache2
echo "scenario_seed: apache + mod_http2 + self-signed placeholder in h2.conf"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # http2 must still be loaded after certberus is done.
    if ! box_ssh "$BOX" 'apachectl -M 2>/dev/null | grep -q http2_module'; then
        echo "scenario_post_verify: FAIL - http2_module is no longer loaded"
        return 1
    fi
    echo "scenario_post_verify: OK (http2_module still loaded)"
}
