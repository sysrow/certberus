#!/bin/bash
# C-23: an unrelated `certbot renew --quiet` cron job runs every 5 minutes
# for a dead domain (dead.invalid). The cron job races with certberus and
# may try to grab :80 via the standalone authenticator. Verifies that
# certberus' lock + webserver integration doesn't get corrupted by a
# concurrent stray certbot.

SCENARIO_ID="c-23"
SCENARIO_NAME="Stray certbot renew cron every 5 minutes for a dead domain"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s123.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md certbot

mkdir -p /etc/letsencrypt/renewal \
         /etc/letsencrypt/live/dead.invalid \
         /etc/letsencrypt/archive/dead.invalid

echo dummy > /etc/letsencrypt/archive/dead.invalid/fullchain1.pem
echo dummy > /etc/letsencrypt/archive/dead.invalid/privkey1.pem
echo dummy > /etc/letsencrypt/archive/dead.invalid/chain1.pem
echo dummy > /etc/letsencrypt/archive/dead.invalid/cert1.pem

ln -sf ../../archive/dead.invalid/fullchain1.pem /etc/letsencrypt/live/dead.invalid/fullchain.pem
ln -sf ../../archive/dead.invalid/privkey1.pem   /etc/letsencrypt/live/dead.invalid/privkey.pem
ln -sf ../../archive/dead.invalid/chain1.pem     /etc/letsencrypt/live/dead.invalid/chain.pem
ln -sf ../../archive/dead.invalid/cert1.pem      /etc/letsencrypt/live/dead.invalid/cert.pem

cat >/etc/letsencrypt/renewal/dead.invalid.conf <<EOF
# managed by Certbot
cert = /etc/letsencrypt/live/dead.invalid/cert.pem
privkey = /etc/letsencrypt/live/dead.invalid/privkey.pem
chain = /etc/letsencrypt/live/dead.invalid/chain.pem
fullchain = /etc/letsencrypt/live/dead.invalid/fullchain.pem
[renewalparams]
account = nonexistent
authenticator = standalone
installer = None
EOF

cat >/etc/cron.d/zz-certbot-race <<'EOF'
*/5 * * * * root /usr/bin/certbot renew --quiet
EOF
chmod 644 /etc/cron.d/zz-certbot-race

systemctl enable --now apache2
systemctl reload cron 2>/dev/null || systemctl restart cron 2>/dev/null || true
echo "scenario_seed: stray certbot renew cron installed; dead.invalid renewal config in place"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
