#!/bin/bash
# C-06: Two distinct <VirtualHost *:443> blocks both declaring the same
# ServerName, each pointing at different stale SSLCertificate paths. Real
# admins end up here by copy-pasting a vhost to "test something" and never
# disabling the old one. Verifies certberus picks a coherent path forward
# instead of leaving Apache with ambiguous SSL config.

SCENARIO_ID="c-06"
SCENARIO_NAME="Two conflicting :443 vhosts with same ServerName"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s106.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md openssl
a2enmod ssl >/dev/null

# Self-signed seed cert referenced by vhost-a.
openssl req -x509 -newkey rsa:2048 \
    -keyout /etc/ssl/private/seed.key \
    -out /etc/ssl/certs/seed.crt \
    -days 30 -nodes \
    -subj "/CN=$FQDN" 2>/dev/null

# vhost-b references a path that does not even exist on disk (the admin
# deleted the cert but forgot the vhost).
cat >/etc/apache2/sites-available/vhost-a.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/seed.crt
    SSLCertificateKeyFile /etc/ssl/private/seed.key
    DocumentRoot /var/www/html
</VirtualHost>
EOF

cat >/etc/apache2/sites-available/vhost-b.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/old-other.crt
    SSLCertificateKeyFile /etc/ssl/private/old-other.key
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite vhost-a vhost-b >/dev/null

# Apache will warn here; we tolerate either reload or restart succeeding.
apache2ctl -t || true
systemctl reload apache2 || systemctl restart apache2 || true
echo "scenario_seed: two conflicting :443 vhosts enabled for $FQDN"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
