#!/bin/bash
# A-02: replicate the oidc bug — Apache + a custom :443 vhost with hardcoded
# SSLCertificateFile pointing at a pre-seeded certbot path. Verifies that the
# patched stage_fix_ssl_vhosts comments those directives out so mod_md can
# serve its own cert (and tls-alpn-01 stops getting "answer to challenge
# invalid").
#
# Seed flow:
#   1. apt install apache2 + libapache2-mod-md + certbot
#   2. Pre-issue a real LE-staging cert via certbot --standalone for the FQDN
#      (this also creates the /etc/letsencrypt/live/<FQDN>/ paths the user's
#      vhost will reference).
#   3. Drop a vhost that mirrors the oidc setup: explicit SSLCertificateFile
#      pointing at the pre-issued cert, :80 redirect with ACME exemption.
#   4. Reload apache.
#
# Expectation:
#   `certberus install --webserver apache` comments out the hardcoded
#   SSLCertificate* lines in the :443 block, generates certberus-md.conf with
#   MDomain <FQDN>, mod_md issues a NEW cert via HTTP-01 (tls-alpn-01 also
#   works now that the explicit path is gone), and openssl s_client from
#   tristram sees a cert with notBefore > the pre-seeded one.

SCENARIO_ID="a-02"
SCENARIO_NAME="Apache + existing certbot cert + hardcoded SSLCertificateFile (oidc bug)"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s002.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md certbot

systemctl enable --now apache2
a2enmod ssl rewrite headers >/dev/null

# Pre-issue an LE-staging cert via certbot --standalone. Apache must be
# stopped briefly so certbot can bind :80.
systemctl stop apache2
certbot certonly --standalone --non-interactive --agree-tos \
    -m ${CB_E2E_EMAIL} --staging -d "$FQDN" \
    >/tmp/certbot-pre.log 2>&1 || {
        echo "certbot pre-seed FAILED"
        tail -50 /tmp/certbot-pre.log
        exit 1
    }
systemctl start apache2

# Drop the oidc-style vhost.
cat >/etc/apache2/sites-available/scenario-a02.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/$FQDN/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/$FQDN/privkey.pem
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    Header always set Strict-Transport-Security "max-age=31536000"
    DocumentRoot /var/www/html
</VirtualHost>

<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
    RewriteEngine on
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite scenario-a02 >/dev/null
apache2ctl -t
systemctl reload apache2

# Capture pre-seed cert fingerprint for the post-verify diff.
openssl x509 -in "/etc/letsencrypt/live/$FQDN/fullchain.pem" -noout -fingerprint -sha256 \
    > /tmp/scenario-a02.preseed.fp
echo "scenario_seed: pre-seeded $(cat /tmp/scenario-a02.preseed.fp)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # Pull the new live cert from outside and compare its fingerprint to the
    # pre-seeded one. A fresh issuance MUST have a different fingerprint.
    local new_fp pre_fp
    new_fp=$(timeout 15 openssl s_client -servername "$FQDN" -connect "$FQDN:443" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    pre_fp=$(box_ssh "$BOX" 'cat /tmp/scenario-a02.preseed.fp 2>/dev/null')
    echo "scenario_post_verify: pre = $pre_fp"
    echo "scenario_post_verify: new = $new_fp"
    if [[ -z "$pre_fp" || "$new_fp" == "$pre_fp" ]]; then
        echo "scenario_post_verify: FAIL — new cert fingerprint matches pre-seed (mod_md did not actually re-issue)"
        return 1
    fi
    # Additionally confirm the patched apache-md.sh commented the SSLCert* lines.
    box_ssh "$BOX" "grep -q '# certberus: managed by mod_md' /etc/apache2/sites-enabled/scenario-a02.conf" \
        || { echo "scenario_post_verify: FAIL — no commenting marker in vhost"; return 1; }
    echo "scenario_post_verify: OK (new fingerprint + commenting marker present)"
}
