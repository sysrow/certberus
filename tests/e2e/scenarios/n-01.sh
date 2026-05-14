#!/bin/bash
# N-01: nginx with a hardcoded self-signed ssl_certificate / ssl_certificate_key
# pair already in the server block. Replicates an admin who set up nginx
# with a placeholder cert and never replaced it. certberus must rewrite the
# directives to point at the new LE cert WITHOUT appending duplicates -
# nginx silently uses the first ssl_certificate, so a duplicate-and-leak
# pattern would keep the self-signed live.

SCENARIO_ID="n-01"
SCENARIO_NAME="nginx with hardcoded self-signed cert - no duplicates after rewrite"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s201.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install nginx

mkdir -p /etc/ssl/private
openssl req -x509 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$FQDN.key" \
    -out "/etc/ssl/certs/$FQDN.crt" \
    -days 30 -nodes -subj "/CN=$FQDN" 2>/dev/null
chmod 600 "/etc/ssl/private/$FQDN.key"

cat >/etc/nginx/sites-available/seeded.conf <<EOF
server {
    listen 80;
    listen 443 ssl;
    server_name $FQDN;
    root /var/www/html;
    ssl_certificate     /etc/ssl/certs/$FQDN.crt;
    ssl_certificate_key /etc/ssl/private/$FQDN.key;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/seeded.conf /etc/nginx/sites-enabled/seeded.conf
nginx -t
systemctl reload nginx || systemctl restart nginx
echo "scenario_seed: nginx with hardcoded self-signed ssl_certificate pair"
REMOTE
}

scenario_install_args() {
    echo "--webserver nginx --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

scenario_post_verify() {
    # The active server block must end up with exactly one ssl_certificate
    # directive. Duplicates indicate certberus appended rather than replaced.
    local count
    count=$(box_ssh "$BOX" \
        'grep -E "^[[:space:]]*ssl_certificate[[:space:]]" /etc/nginx/sites-enabled/seeded.conf 2>/dev/null | wc -l')
    echo "scenario_post_verify: ssl_certificate count = $count"
    if [[ "$count" != "1" ]]; then
        echo "scenario_post_verify: FAIL - expected exactly 1 ssl_certificate, found $count"
        return 1
    fi
    echo "scenario_post_verify: OK (single ssl_certificate directive)"
}
