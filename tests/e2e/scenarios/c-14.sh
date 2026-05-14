#!/bin/bash
# C-14: vhost ServerName written with mixed case (e.g. Foo.Debian13.Example)
# while the certberus CLI is invoked with the lowercase form. DNS is
# case-insensitive and Apache normalises during matching, but a sloppy
# vhost-discovery pipeline can miss the match. Verifies certberus matches
# vhosts case-insensitively.

SCENARIO_ID="c-14"
SCENARIO_NAME="ServerName uses mixed case vs lowercase CLI domain"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s114.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

# Capitalise the first letter of each label so e.g. "foo.example.test"
# becomes "Foo.Example.Test".
UPPER=$(echo "$FQDN" | sed -E 's/^([a-z])/\U\1/; s/\.([a-z])/.\U\1/g')

cat >/etc/apache2/sites-available/case.conf <<EOF
<VirtualHost *:80>
    ServerName $UPPER
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite case >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: vhost ServerName=$UPPER (mixed case) enabled"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
