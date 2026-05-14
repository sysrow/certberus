#!/bin/bash
# C-07: ports.conf rewritten to use 'Listen 0.0.0.0:443' rather than the
# Debian default 'Listen 443'. Many hardening guides recommend explicit bind
# addresses; the syntactic form trips up tools that grep ports.conf for an
# exact 'Listen 443' line. Verifies certberus install handles this variant.

SCENARIO_ID="c-07"
SCENARIO_NAME="ports.conf uses Listen 0.0.0.0:443 instead of Listen 443"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s107.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md

# Rewrite the plain "Listen 443" to a v4-bind form used by some hardening guides.
sed -i 's/^Listen 443$/Listen 0.0.0.0:443/' /etc/apache2/ports.conf

a2enmod ssl >/dev/null
systemctl restart apache2
echo "scenario_seed: ports.conf rewritten to Listen 0.0.0.0:443"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
