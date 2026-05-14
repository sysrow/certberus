#!/bin/bash
# C-16: a previous certbot run failed half-way and left
# /etc/letsencrypt/live/<FQDN>/ populated with dangling symlinks pointing at
# /tmp/does-not-exist. Apache is not yet configured to read those paths, but
# certberus must not get confused by their presence (e.g. by treating the
# directory as "already managed by certbot") and must still issue via mod_md.

SCENARIO_ID="c-16"
SCENARIO_NAME="Dangling /etc/letsencrypt/live/<FQDN>/ symlinks"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s116.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md

mkdir -p "/etc/letsencrypt/live/$FQDN"
ln -s /tmp/does-not-exist "/etc/letsencrypt/live/$FQDN/fullchain.pem"
ln -s /tmp/does-not-exist "/etc/letsencrypt/live/$FQDN/privkey.pem"
ln -s /tmp/does-not-exist "/etc/letsencrypt/live/$FQDN/cert.pem"
ln -s /tmp/does-not-exist "/etc/letsencrypt/live/$FQDN/chain.pem"

systemctl enable --now apache2
echo "scenario_seed: dangling LE live/ symlinks for $FQDN in place"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
