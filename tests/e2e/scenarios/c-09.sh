#!/bin/bash
# C-09: Leftover 'MDPrivateKeys RSA 4096' directive in conf-enabled from a
# previous mod_md trial. Admins frequently set RSA 4096 to satisfy a 2019
# compliance checklist and forget about it. Verifies certberus install
# respects (or overrides) this and that the issued key actually matches.

SCENARIO_ID="c-09"
SCENARIO_NAME="Leftover MDPrivateKeys RSA 4096 directive"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s109.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod md >/dev/null

cat >/etc/apache2/conf-available/zz-keytype.conf <<'EOF'
# Compliance checklist from 2019 wanted RSA 4096 keys for everything.
MDPrivateKeys RSA 4096
EOF

a2enconf zz-keytype >/dev/null
systemctl restart apache2
echo "scenario_seed: MDPrivateKeys RSA 4096 directive active"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # The issued cert must use an RSA 4096 key (matching the directive).
    local pubkey
    pubkey=$(timeout 15 openssl s_client -servername "$FQDN" -connect "$FQDN:443" </dev/null 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null \
        | grep -oE 'Public-Key: \([0-9]+ bit\)' \
        | head -n1) || return 1
    echo "scenario_post_verify: $pubkey"
    if [[ "$pubkey" != "Public-Key: (4096 bit)" ]]; then
        echo "scenario_post_verify: FAIL — expected RSA 4096, got '$pubkey'"
        return 1
    fi
    echo "scenario_post_verify: OK (RSA 4096 cert issued as configured)"
}
