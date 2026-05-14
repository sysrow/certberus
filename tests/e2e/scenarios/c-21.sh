#!/bin/bash
# C-21: the :80 vhost has an aggressive `RewriteRule ^/(.*)$ https://...`
# with no exemption for /.well-known/acme-challenge/. Replicates an admin
# who pasted "force HTTPS everywhere" from a hardening blog. HTTP-01
# challenges will 301 to HTTPS and fail. certberus must either patch the
# rewrite (insert RewriteCond) or fall back to tls-alpn-01.

SCENARIO_ID="c-21"
SCENARIO_NAME="mod_rewrite forces HTTPS with no ACME exemption"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s121.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod rewrite ssl >/dev/null

cat >/etc/apache2/sites-available/forcedssl.conf <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
    RewriteEngine on
    RewriteRule ^/(.*)\$ https://$FQDN/\$1 [R=301,L]
</VirtualHost>
EOF

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite forcedssl >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: :80 vhost force-redirects every request to https (no ACME exemption)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
