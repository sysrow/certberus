#!/bin/bash
# N-03: nginx as a reverse proxy in front of an app on 127.0.0.1:3000. The
# /.well-known/acme-challenge/ path must still resolve via webroot/static or
# certberus needs a strategy that does not require punching a hole through
# the proxy. Crucially the user's proxy_pass and proxy_set_header lines
# MUST still be present in the active config after install - if certberus
# rewrites the whole server block and drops them, the app goes dark.

SCENARIO_ID="n-03"
SCENARIO_NAME="nginx reverse proxy - proxy_pass must survive install"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s203.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install nginx

cat >/etc/nginx/sites-available/rproxy.conf <<EOF
server {
    listen 80;
    server_name $FQDN;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/rproxy.conf /etc/nginx/sites-enabled/rproxy.conf
nginx -t
systemctl reload nginx || systemctl restart nginx
echo "scenario_seed: nginx reverse-proxy vhost (proxy_pass localhost:3000)"
REMOTE
}

scenario_install_args() {
    echo "--webserver nginx --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # The user's proxy_pass directive must still be there after install.
    if ! box_ssh "$BOX" 'grep -q "proxy_pass[[:space:]]\+http://127.0.0.1:3000" /etc/nginx/sites-enabled/rproxy.conf'; then
        echo "scenario_post_verify: FAIL - proxy_pass directive missing from active config"
        return 1
    fi
    if ! box_ssh "$BOX" 'grep -q "proxy_set_header[[:space:]]\+Host" /etc/nginx/sites-enabled/rproxy.conf'; then
        echo "scenario_post_verify: FAIL - proxy_set_header Host directive missing"
        return 1
    fi
    echo "scenario_post_verify: OK (proxy_pass and proxy_set_header preserved)"
}
