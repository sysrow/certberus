#!/bin/bash
# C-13: vhost with trailing whitespace after the ServerName value. Apache
# parses this fine but third-party scrapers (and naive grep|awk pipelines)
# often pick up the trailing spaces and miscompare against the CLI-passed
# FQDN. Verifies certberus normalises whitespace when matching vhosts.

SCENARIO_ID="c-13"
SCENARIO_NAME="ServerName has trailing whitespace"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s113.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

# Use printf so the trailing spaces after the ServerName value are preserved
# verbatim (heredoc editors love to strip trailing whitespace).
printf '%s\n' \
    "<VirtualHost *:80>" \
    "    ServerName ${FQDN}   " \
    "    DocumentRoot /var/www/html" \
    "</VirtualHost>" \
    > /etc/apache2/sites-available/whitespace.conf

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite whitespace >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: vhost with trailing-whitespace ServerName enabled"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
