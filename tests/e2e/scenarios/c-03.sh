#!/bin/bash
# C-03: Apache running with mpm_prefork explicitly enabled. mod_md async
# issuance is happiest on mpm_event; admins who enabled mod_php years ago
# often left prefork in place and never switched back. Verifies that
# certberus install copes (or correctly switches MPM) and still gets a cert.

SCENARIO_ID="c-03"
SCENARIO_NAME="Apache mpm_prefork explicitly enabled"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s103.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md

# Drop event/worker, force prefork (admin set this up for mod_php years ago).
a2dismod mpm_event >/dev/null 2>&1 || true
a2dismod mpm_worker >/dev/null 2>&1 || true
a2enmod mpm_prefork >/dev/null

systemctl restart apache2
echo "scenario_seed: mpm_prefork active, mpm_event disabled"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
