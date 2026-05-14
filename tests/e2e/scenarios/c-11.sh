#!/bin/bash
# C-11: nftables active with an inet filter chain that drops TCP dport 80.
# Replicates the common "I'll just block :80 for now" mistake — http-01
# challenges silently fail. Verifies certberus detects nftables, reconciles
# the rule, and the issuance succeeds.

SCENARIO_ID="c-11"
SCENARIO_NAME="nftables inet filter chain drops TCP dport 80"
SCENARIO_BOX_OK="deb12 deb13"
SCENARIO_FQDN_PATTERN="s111.@{WILDCARD}"

scenario_seed() {
    box_ssh "$BOX" "FQDN='$FQDN' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get -y -qq install apache2 libapache2-mod-md nftables

cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        # Admin blocked :80 "temporarily" two years ago.
        tcp dport 80 drop
    }
}
EOF

systemctl enable nftables >/dev/null
nft -f /etc/nftables.conf
systemctl restart nftables

nft list ruleset
echo "scenario_seed: nft drop rule on tcp dport 80 active"
REMOTE
}

scenario_install_args() {
    echo "--webserver apache --staging --email ${CB_E2E_EMAIL} --domain $FQDN -y"
}
