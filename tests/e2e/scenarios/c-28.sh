#!/bin/bash
# C-28: Idempotence guard. We pre-issue a fresh LE-staging cert via certbot
# standalone, plant a vhost that already references it, and then run
# certberus install. A correctly-behaving certberus must NOT request a new
# certificate when the existing one is still fresh - it should adopt the
# current cert (mod_md takes it over) and leave the fingerprint unchanged.
# If the live cert fingerprint differs from the pre-seeded one after install,
# that is a bug: certberus is burning rate-limit quota for no reason.

SCENARIO_ID="c-28"
SCENARIO_NAME="Existing fresh cert - certberus must be idempotent"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s128.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md certbot

systemctl enable --now apache2
a2enmod ssl rewrite headers >/dev/null

systemctl stop apache2
certbot certonly --standalone --non-interactive --agree-tos \
    -m ${CB_E2E_EMAIL} --staging -d "$FQDN" \
    >/tmp/certbot-pre.log 2>&1 || {
        echo "certbot pre-seed FAILED"
        tail -50 /tmp/certbot-pre.log
        exit 1
    }
systemctl start apache2

cat >/etc/apache2/sites-available/idem.conf <<EOF
<VirtualHost *:443>
    ServerName $FQDN
    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/$FQDN/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/$FQDN/privkey.pem
    DocumentRoot /var/www/html
</VirtualHost>

<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite idem >/dev/null
apache2ctl -t
systemctl reload apache2

# Save the fresh fingerprint for the post-verify diff.
openssl x509 -in "/etc/letsencrypt/live/$FQDN/fullchain.pem" \
    -noout -fingerprint -sha256 > /tmp/idem.pre.fp
echo "scenario_seed: pre-seeded $(cat /tmp/idem.pre.fp)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # The live cert's fingerprint MUST match what we pre-seeded. If it does
    # not, certberus re-issued an already-fresh certificate, which is the bug
    # this scenario hunts for.
    local new_fp pre_fp
    new_fp=$(timeout 15 openssl s_client -servername "$FQDN" -connect "$FQDN:443" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    pre_fp=$(box_ssh "$BOX" 'cat /tmp/idem.pre.fp 2>/dev/null')
    echo "scenario_post_verify: pre = $pre_fp"
    echo "scenario_post_verify: new = $new_fp"
    if [[ -z "$pre_fp" || -z "$new_fp" ]]; then
        echo "scenario_post_verify: FAIL - missing fingerprint(s)"
        return 1
    fi
    if [[ "$new_fp" != "$pre_fp" ]]; then
        echo "scenario_post_verify: FAIL - certberus re-issued a fresh cert (idempotence broken)"
        return 1
    fi
    echo "scenario_post_verify: OK (fingerprint unchanged, idempotent)"
}
