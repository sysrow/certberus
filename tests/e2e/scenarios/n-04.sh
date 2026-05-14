#!/bin/bash
# N-04: nginx server block listens ONLY on 443 with a self-signed cert -
# there is no :80 listener for the FQDN at all. Replicates an admin who
# decided "HTTPS-only" and removed every :80 block. ACME http-01 needs :80
# to be reachable; certberus must either add a :80 listener (preferred) or
# fall back to a standalone strategy that can bind :80 briefly. Either way
# the install must succeed end-to-end.

SCENARIO_ID="n-04"
SCENARIO_NAME="nginx with only :443 listener - no :80 anywhere"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s204.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install nginx

mkdir -p /etc/ssl/private
openssl req -x509 -newkey rsa:2048 \
    -keyout /etc/ssl/private/seed.key \
    -out /etc/ssl/certs/seed.crt \
    -days 30 -nodes -subj "/CN=$FQDN" 2>/dev/null
chmod 600 /etc/ssl/private/seed.key

cat >/etc/nginx/sites-available/only443.conf <<EOF
server {
    listen 443 ssl;
    server_name $FQDN;
    ssl_certificate     /etc/ssl/certs/seed.crt;
    ssl_certificate_key /etc/ssl/private/seed.key;
    root /var/www/html;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/only443.conf /etc/nginx/sites-enabled/only443.conf
nginx -t
systemctl reload nginx || systemctl restart nginx
echo "scenario_seed: nginx with only :443 listener (no :80 server block)"
REMOTE
}

scenario_install_args() {
    echo "--webserver nginx --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
