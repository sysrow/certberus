#!/bin/bash
# U-01: No webserver at all. Just certbot is installed. certberus must drive
# the standalone path (certbot --standalone or its own equivalent), bind :80
# briefly, complete http-01 validation, and end with a usable cert under
# /etc/letsencrypt/live/<FQDN>/. This is the "I just need a cert for a
# service that isn't HTTP" workflow.

SCENARIO_ID="u-01"
SCENARIO_NAME="certbot-only standalone, no webserver installed"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s301.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install certbot

# Make sure nothing is squatting on :80 / :443.
systemctl stop apache2 nginx 2>/dev/null || true
systemctl disable apache2 nginx 2>/dev/null || true
echo "scenario_seed: certbot installed, no webserver running"
REMOTE
}

scenario_install_args() {
    echo "--webserver certbot-only --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
