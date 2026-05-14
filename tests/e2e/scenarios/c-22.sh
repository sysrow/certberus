#!/bin/bash
# C-22: the vhost uses Apache `Define`/`${MYDOM}` macros instead of a literal
# ServerName. Common in multi-tenant configs where the hostname is templated
# out. certberus' config parser must either expand the macro or pick up the
# domain from another source (CLI flag) without choking on the literal
# `${MYDOM}` string in ServerName.

SCENARIO_ID="c-22"
SCENARIO_NAME="Apache Define macro used for ServerName (\${MYDOM})"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s122.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

cat >/etc/apache2/conf-available/zz-vars.conf <<EOF
Define MYDOM $FQDN
EOF
a2enconf zz-vars >/dev/null

cat >/etc/apache2/sites-available/macro.conf <<'EOF'
<VirtualHost *:80>
    ServerName ${MYDOM}
    DocumentRoot /var/www/html
</VirtualHost>
EOF

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite macro >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: vhost ServerName uses \${MYDOM} macro defined in zz-vars.conf"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
