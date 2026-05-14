#!/bin/bash
# C-04: Custom global Mutex directive left over from a 2021 troubleshooting
# session (the classic "mod_ssl could not create mutex" StackOverflow fix).
# The directive lives in conf-enabled and overrides Apache's default. Verifies
# certberus install still works when global Mutex configuration is non-default.

SCENARIO_ID="c-04"
SCENARIO_NAME="Custom global Mutex file directive in apache2.conf"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s104.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md

mkdir -p /var/lock/apache2
chown root:root /var/lock/apache2

cat >/etc/apache2/conf-available/zz-custom-mutex.conf <<'EOF'
# Pasted from an old SO answer in 2021 to fix "could not create SSLMutex"
Mutex file:/var/lock/apache2 default
EOF

a2enconf zz-custom-mutex >/dev/null
systemctl restart apache2
echo "scenario_seed: custom global Mutex directive active"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
