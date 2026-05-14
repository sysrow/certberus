#!/bin/bash
# A-01: clean Apache + libapache2-mod-md, default 000-default only, install
# certberus against LE staging. Baseline happy path for mod_md.

SCENARIO_ID="a-01"
SCENARIO_NAME="Clean Apache + mod_md, default vhost only"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s001.@{WILDCARD}"

scenario_seed() {
    # Install only the base apache2; certberus must detect and install
    # libapache2-mod-md itself on releases where it is a separate package
    # (Debian 12 bookworm). On Debian 13 trixie mod_md.so ships inside
    # apache2-bin, so no extra package is needed.
    box_ssh "$BOX" 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -y -qq install apache2 certbot
systemctl enable --now apache2
echo "scenario_seed: apache2 + certbot installed (mod_md left for certberus to provision)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
