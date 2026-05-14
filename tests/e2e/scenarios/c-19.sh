#!/bin/bash
# C-19: apache2 is `systemctl mask`-ed (admin debugged something months ago,
# stopped & masked the unit, forgot to unmask). certberus install must detect
# the mask and either unmask it or report a clear actionable error — silent
# failure to start apache after issuance would be the worst outcome.

SCENARIO_ID="c-19"
SCENARIO_NAME="apache2 is systemctl-masked before install"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s119.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md

systemctl stop apache2 || true
systemctl mask apache2

echo "scenario_seed: apache2 unit state:"
systemctl is-enabled apache2 || true
systemctl status apache2 --no-pager 2>&1 | head -5 || true
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
