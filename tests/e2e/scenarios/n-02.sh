#!/bin/bash
# N-02: nginx with location / { try_files $uri =404; } that intercepts every
# request including /.well-known/acme-challenge/*. Replicates a common
# static-site config (or single-page-app) where the admin returns 404 for
# anything missing. certberus must either insert an explicit ACME location
# block above the catch-all or use a strategy that does not depend on
# webroot under that server.

SCENARIO_ID="n-02"
SCENARIO_NAME="nginx try_files catch-all swallowing ACME path"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s202.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install nginx

cat >/etc/nginx/sites-available/tryfiles.conf <<EOF
server {
    listen 80;
    server_name $FQDN;
    root /var/www/html;
    location / {
        try_files \$uri =404;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/tryfiles.conf /etc/nginx/sites-enabled/tryfiles.conf
nginx -t
systemctl reload nginx || systemctl restart nginx
echo "scenario_seed: nginx with try_files =404 catch-all"
REMOTE
}

scenario_install_args() {
    echo "--webserver nginx --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
