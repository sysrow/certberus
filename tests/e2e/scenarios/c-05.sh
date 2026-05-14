#!/bin/bash
# C-05: Leftover MDStoreDir pointing at a path that no longer exists, plus an
# MDCAChallenges override. Replicates an admin who once tried mod_md against a
# private CA at /opt/old-md-store, gave up, and removed only the directory —
# the conf snippet is still active in conf-enabled. Verifies certberus either
# reconciles MDStoreDir or fails loudly instead of silently using the broken
# path.

SCENARIO_ID="c-05"
SCENARIO_NAME="Stale MDStoreDir pointing at non-existent path"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s105.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod md >/dev/null

cat >/etc/apache2/conf-available/zz-old-md.conf <<'EOF'
# Left over from a previous mod_md trial against an internal CA in 2022.
# /opt/old-md-store was deleted but this snippet was forgotten.
MDStoreDir /opt/old-md-store
MDCAChallenges http-01
EOF

a2enconf zz-old-md >/dev/null
systemctl restart apache2
echo "scenario_seed: stale MDStoreDir directive active, /opt/old-md-store does not exist"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
