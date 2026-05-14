#!/bin/bash
# C-24: the admin has pre-configured `MDMessageCmd /opt/old-hook.sh` in
# /etc/apache2/conf-available/zz-old-hook.conf — e.g. an existing pipeline
# that emails the team when mod_md renews. certberus' hook integration must
# not silently nuke that — it should either coexist (run both via the hooks
# adapter) or, at minimum, leave a discoverable trace so the admin can
# notice their hook stopped firing.

SCENARIO_ID="c-24"
SCENARIO_NAME="Pre-existing MDMessageCmd hook configured by the admin"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s124.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md
a2enmod md >/dev/null

cat >/opt/old-hook.sh <<'EOF'
#!/bin/bash
echo "$(date -Is) $*" >> /tmp/old-hook.log
EOF
chmod +x /opt/old-hook.sh

cat >/etc/apache2/conf-available/zz-old-hook.conf <<'EOF'
MDMessageCmd /opt/old-hook.sh
EOF
a2enconf zz-old-hook >/dev/null

systemctl restart apache2
echo "scenario_seed: MDMessageCmd /opt/old-hook.sh configured via zz-old-hook.conf"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}

# Assert that the admin's pre-existing /opt/old-hook.sh reference is NOT
# silently deleted. We accept three outcomes as non-broken:
#   1. The original zz-old-hook.conf still exists and is still enabled.
#   2. /opt/old-hook.sh is referenced from any apache config file (it was
#      relocated by certberus, e.g. wrapped into an adapter).
#   3. certberus has dropped a hook-adapter file that mentions old-hook.sh.
# We require at least ONE of those. If none holds, certberus has silently
# clobbered the user's hook — that's the bug we want to surface.
scenario_post_verify() {
    local found=0

    if box_ssh "$BOX" 'test -e /etc/apache2/conf-enabled/zz-old-hook.conf'; then
        echo "scenario_post_verify: original zz-old-hook.conf still enabled"
        found=1
    fi

    if box_ssh "$BOX" 'grep -rqsF "/opt/old-hook.sh" /etc/apache2/ 2>/dev/null'; then
        echo "scenario_post_verify: /opt/old-hook.sh still referenced somewhere in /etc/apache2"
        found=1
    fi

    echo "scenario_post_verify: current MDMessageCmd lines visible to apache:"
    box_ssh "$BOX" 'grep -rhsE "^[[:space:]]*MDMessageCmd" /etc/apache2/ 2>/dev/null || true'

    if [[ $found -eq 0 ]]; then
        echo "scenario_post_verify: FAIL - admin's MDMessageCmd /opt/old-hook.sh was silently removed"
        return 1
    fi
    echo "scenario_post_verify: OK - admin's hook was preserved or visibly relocated"
}
