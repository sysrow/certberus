#!/bin/bash
# C-08: SSLCertificateFile / SSLCertificateKeyFile wrapped inside an
# <IfModule mod_ssl.c> guard. This is a defensive pattern copy-pasted from
# the upstream default-ssl vhost and confuses naive sed-based rewriters.
# Verifies that certberus install correctly neutralises the hardcoded paths
# (commenting marker) even when they sit inside an IfModule block.

SCENARIO_ID="c-08"
SCENARIO_NAME="SSLCertificateFile inside <IfModule mod_ssl.c> guard"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s108.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md certbot
a2enmod ssl >/dev/null

# Pre-issue an LE-staging cert so the wrapped vhost has real files to point at.
systemctl stop apache2
certbot certonly --standalone --non-interactive --agree-tos \
    -m ${CB_E2E_EMAIL} --staging -d "$FQDN" \
    >/tmp/certbot-pre.log 2>&1 || {
        echo "certbot pre-seed FAILED"
        tail -50 /tmp/certbot-pre.log
        exit 1
    }
systemctl start apache2

cat >/etc/apache2/sites-available/wrapped.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    <IfModule mod_ssl.c>
        SSLEngine on
        SSLCertificateFile      /etc/letsencrypt/live/$FQDN/fullchain.pem
        SSLCertificateKeyFile   /etc/letsencrypt/live/$FQDN/privkey.pem
    </IfModule>
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite wrapped >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: wrapped IfModule vhost enabled for $FQDN"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # The patched apache-md.sh should have commented out the SSLCert lines
    # even though they sit inside an IfModule block.
    box_ssh "$BOX" "grep -q '# certberus: managed by mod_md' /etc/apache2/sites-enabled/wrapped.conf" \
        || { echo "scenario_post_verify: FAIL — no commenting marker in wrapped vhost"; return 1; }
    echo "scenario_post_verify: OK (commenting marker present inside IfModule)"
}
