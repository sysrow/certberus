#!/bin/bash
# N-05: nginx default_server with server_name _ that returns 444 for
# anything. The FQDN we are issuing for is not mentioned anywhere in the
# config. Replicates the "I only have a catch-all on :80 because I locked
# the box down" state. certberus must either inject a matching server block
# for the FQDN or use a non-webroot strategy - if it just drops the
# challenge into a webroot that the catch-all returns 444 from, validation
# will fail.

SCENARIO_ID="n-05"
SCENARIO_NAME="nginx default_server returning 444, FQDN not in any server_name"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s205.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install nginx

cat >/etc/nginx/sites-available/nomatch.conf <<EOF
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    location / {
        return 444;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/nomatch.conf /etc/nginx/sites-enabled/nomatch.conf
nginx -t
systemctl reload nginx || systemctl restart nginx
echo "scenario_seed: nginx default_server returning 444, no server_name for $FQDN"
REMOTE
}

scenario_install_args() {
    echo "--webserver nginx --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
