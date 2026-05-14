#!/bin/bash
# C-29: Corporate ACL trap. The :80 vhost wraps the entire document root in
# <Location /> Require ip 10.0.0.0/8 </Location> with no exemption for
# /.well-known/acme-challenge/. This is what happens when an admin copies
# an internal-only vhost template and never adds an ACME exemption. The
# Let's Encrypt validator will be 403'd. We expect either:
#   - preflight detects the unreachable challenge path and reports it, or
#   - the install fails clearly rather than spinning until timeout.

SCENARIO_ID="c-29"
SCENARIO_NAME="Apache vhost with Require ip ACL blocking ACME path"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s129.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod ssl >/dev/null

cat >/etc/apache2/sites-available/acl.conf <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot /var/www/html
    <Location />
        Require ip 10.0.0.0/8
    </Location>
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite acl >/dev/null
apache2ctl -t
systemctl reload apache2
echo "scenario_seed: :80 vhost with Require ip 10.0.0.0/8 and no ACME exemption"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
