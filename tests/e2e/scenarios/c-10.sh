#!/bin/bash
# C-10: ufw active with default-deny incoming and only SSH allowed. Replicates
# a freshly hardened box where the admin remembered SSH but not :80/:443.
# Verifies certberus detects the firewall, opens the right ports, and the
# ACME http-01 challenge actually completes.

SCENARIO_ID="c-10"
SCENARIO_NAME="ufw default-deny, only SSH allowed"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s110.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md ufw

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null

ufw status verbose
echo "scenario_seed: ufw active, default deny, only :22 open"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
