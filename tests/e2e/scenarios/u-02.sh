#!/bin/bash
# U-02: Caddy native ACME (deb13 trixie only - deb12 has caddy only via
# testing). The Caddyfile is already set up to talk to LE staging directly,
# so certberus's job here is the "managed by Caddy" path: detect that
# Caddy owns ACME, configure/restart Caddy as needed, and not fight it
# with a parallel certbot run. The live cert must come from LE staging via
# Caddy's own client.

SCENARIO_ID="u-02"
SCENARIO_NAME="Caddy native ACME (deb13)"
SCENARIO_BOX_OK="deb13"
SCENARIO_FQDN_PATTERN="s302.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install caddy
systemctl stop caddy 2>/dev/null || true

cat >/etc/caddy/Caddyfile <<EOF
{
    email ${CB_E2E_EMAIL}
    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

$FQDN {
    respond "ok"
}
EOF

systemctl start caddy
echo "scenario_seed: caddy installed with LE-staging Caddyfile for $FQDN"
REMOTE
}

scenario_install_args() {
    echo "--webserver caddy --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
