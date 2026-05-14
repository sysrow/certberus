#!/bin/bash
# C-17: /etc/apache2/md (mod_md state directory) is a dangling symlink to a
# non-existent /opt/nonexistent-store. Replicates an admin who tried to move
# the mod_md store onto a separate disk that later went away. Apache may not
# even start in this state — certberus must detect and repair (or refuse
# cleanly) instead of looping on a broken store.

SCENARIO_ID="c-17"
SCENARIO_NAME="/etc/apache2/md is a dangling symlink"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s117.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod md >/dev/null

systemctl stop apache2 || true
rm -rf /etc/apache2/md
ln -s /opt/nonexistent-store /etc/apache2/md

# Apache may fail to start with a broken md store; ignore so seed succeeds.
systemctl start apache2 2>/dev/null || true
echo "scenario_seed: /etc/apache2/md is now a dangling symlink to /opt/nonexistent-store"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
