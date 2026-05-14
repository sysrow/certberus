#!/bin/bash
# C-18: libapache2-mod-md is marked `apt-mark hold` because the admin once
# hit a dpkg conflict and pinned the package out of frustration. certberus
# must either lift the hold (and document it) or fail with a clear actionable
# error — not a generic apt failure halfway through. Deb12 only: on deb13
# (trixie) mod_md ships inside apache2-bin so this concept doesn't apply.

SCENARIO_ID="c-18"
SCENARIO_NAME="apt-mark hold libapache2-mod-md (deb12 only)"
SCENARIO_BOX_OK="deb12"
SCENARIO_FQDN_PATTERN="s118.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2
apt-mark hold libapache2-mod-md

systemctl enable --now apache2
echo "scenario_seed: libapache2-mod-md is on hold:"
apt-mark showhold | grep -E '^libapache2-mod-md$' || true
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
