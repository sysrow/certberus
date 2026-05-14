#!/bin/bash
# C-30: SAN cert covering apex + www. We pass two --domain flags on the CLI
# but the pre-existing vhost only references the apex. mod_md must end up
# with MDomain covering both, and the live cert must include both names in
# its SAN. The www host resolves via the wildcard DNS we already have, so LE
# can validate both.

SCENARIO_ID="c-30"
SCENARIO_NAME="Apache SAN cert apex + www"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s130.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

cat >/etc/apache2/sites-available/apex.conf <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite apex >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: apex-only vhost (www will be added via certberus CLI)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN --domain www.$FQDN -y"
}

scenario_post_verify() {
    # The served cert must list both names as SANs.
    local sans
    sans=$(timeout 15 openssl s_client -servername "$FQDN" -connect "$FQDN:443" </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null) || return 1
    echo "scenario_post_verify: SANs = $sans"
    if ! grep -q "DNS:$FQDN" <<<"$sans"; then
        echo "scenario_post_verify: FAIL - apex $FQDN missing from SAN"
        return 1
    fi
    if ! grep -q "DNS:www.$FQDN" <<<"$sans"; then
        echo "scenario_post_verify: FAIL - www.$FQDN missing from SAN"
        return 1
    fi
    echo "scenario_post_verify: OK (both names in SAN)"
}
