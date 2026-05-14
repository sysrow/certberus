#!/bin/bash
# C-15: Apache vhost on :80 declares 30 ServerAlias entries, only the FQDN is
# real — the other 29 are dead names. Simulates an admin who accumulated old
# aliases over years and never cleaned them up. We pass only the FQDN on the
# certberus CLI; the question is whether MDomain ends up with only resolvable
# names or whether certberus blindly imports the dead aliases and trips an
# ACME order with unresolvable identifiers.

SCENARIO_ID="c-15"
SCENARIO_NAME="Apache vhost with 30 ServerAlias entries, 29 dead"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s115.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

{
    echo "<VirtualHost *:80>"
    echo "    ServerName $FQDN"
    for i in $(seq 1 29); do
        echo "    ServerAlias dead${i}.example.invalid"
    done
    echo "    DocumentRoot /var/www/html"
    echo "</VirtualHost>"
} >/etc/apache2/sites-available/aliases.conf

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite aliases >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: vhost with 30 ServerAlias entries enabled (1 real + 29 dead)"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
