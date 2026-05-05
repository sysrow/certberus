#!/bin/bash
# tests/integration/test-mod-md-pebble.sh
#
# End-to-end test: certberus + Apache mod_md against a local Pebble
# (reference mini-ACME server by Let's Encrypt). Verifies:
#   1) certberus auto generates MDomain config + adapter in /opt/certberus
#   2) Adapter has correct access permissions (rwx for www-data),
#      otherwise mod_md reports 'MDMessageCmd ... failed with exit code 255'
#   3) /etc/certberus + hooks/*.d are traversable by www-data
#   4) HTTP-01 challenge passes against Pebble (port 80)
#   5) Cert is issued (pubcert.pem in /etc/apache2/md/domains/<dom>/)
#   6) Apache serves the cert on :443 (issuer = Pebble Intermediate CA)
#   7) MDMessageCMD adapter writes installed/renewed event to log
#      and graceful reload completes
#
# Usage:
#   bash tests/integration/test-mod-md-pebble.sh
#   bash tests/integration/test-mod-md-pebble.sh --keep    # keep containers
#
# Exit codes:
#   0   all passed
#   1   an assert failed
#   77  docker not available (skip)

set -uo pipefail

CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP=0
DOMAIN="test.cb.local"
NETWORK="cb-pebble-test"
PEBBLE_NAME="cb-pebble-test-pebble"
CHALL_NAME="cb-pebble-test-challtestsrv"
APACHE_NAME="cb-pebble-test-apache"
WORK_DIR="${TMPDIR:-/tmp}/cb-pebble-test.$$"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1 ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done

# -------- preflight --------
if ! command -v docker >/dev/null 2>&1; then
    echo "[SKIP] docker not available"
    exit 77
fi
if ! docker info >/dev/null 2>&1; then
    echo "[SKIP] docker daemon unavailable"
    exit 77
fi

PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
nok()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

# -------- cleanup --------
cleanup() {
    if [[ "$KEEP" == "1" ]]; then
        echo "--- --keep set, keeping containers (network=$NETWORK, work=$WORK_DIR) ---"
        return 0
    fi
    docker rm -f "$APACHE_NAME" "$PEBBLE_NAME" "$CHALL_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# -------- setup --------
mkdir -p "$WORK_DIR"

echo "### 1) Creating docker network $NETWORK ###"
docker network create "$NETWORK" >/dev/null || { echo "network create failed"; exit 1; }

echo "### 2) Starting challtestsrv (DNS + chall server) ###"
docker run -d --name "$CHALL_NAME" --network "$NETWORK" --network-alias challtestsrv \
    ghcr.io/letsencrypt/pebble-challtestsrv:latest \
    -dnsserver ':53' -http01 '' -https01 '' -tlsalpn01 '' -doh '' \
    -management ':8055' -defaultIPv4 '' -defaultIPv6 '' >/dev/null \
    || { echo "challtestsrv start failed"; exit 1; }

echo "### 3) Generating pebble-config.json (httpPort=80) ###"
cat > "$WORK_DIR/pebble-config.json" <<EOF
{
    "pebble": {
        "listenAddress": "0.0.0.0:14000",
        "managementListenAddress": "0.0.0.0:15000",
        "certificate": "test/certs/localhost/cert.pem",
        "privateKey": "test/certs/localhost/key.pem",
        "httpPort": 80,
        "tlsPort": 443,
        "ocspResponderURL": "",
        "externalAccountBindingRequired": false
    }
}
EOF

echo "### 4) Starting pebble with -config (httpPort=80, validation against vhost) ###"
docker run -d --name "$PEBBLE_NAME" --network "$NETWORK" --network-alias pebble \
    -e PEBBLE_VA_NOSLEEP=1 \
    -e PEBBLE_AUTHZREUSE=100 \
    -v "$WORK_DIR/pebble-config.json:/test/my-config.json:ro" \
    ghcr.io/letsencrypt/pebble:latest \
    -dnsserver challtestsrv:53 -config /test/my-config.json >/dev/null \
    || { echo "pebble start failed"; exit 1; }

# wait for pebble to come up (ACME directory available)
for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker logs "$PEBBLE_NAME" 2>&1 | grep -q "ACME directory available"; then
        break
    fi
    sleep 1
done

echo "### 5) Building cb-apache image (debian:12 + apache2 + mod_md + ca-certificates) ###"
APACHE_IMG="cb-pebble-test-apache-img"
if ! docker image inspect "$APACHE_IMG" >/dev/null 2>&1; then
    DOCKERFILE="$WORK_DIR/Dockerfile"
    cat > "$DOCKERFILE" <<'DOCKER'
FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 libapache2-mod-md sudo \
        python3 openssl ca-certificates curl iproute2 && \
    rm -rf /var/lib/apt/lists/*
RUN a2enmod md ssl headers >/dev/null 2>&1 && \
    a2dissite 000-default default-ssl 2>/dev/null || true
DOCKER
    docker build --network=host -t "$APACHE_IMG" -f "$DOCKERFILE" "$WORK_DIR" \
        >"$WORK_DIR/build.log" 2>&1 || {
        echo "image build failed:"; tail -30 "$WORK_DIR/build.log"; exit 1;
    }
fi

echo "### 6) Starting $APACHE_NAME ###"
docker run -d --name "$APACHE_NAME" --network "$NETWORK" \
    --dns "$(docker inspect -f '{{(index .NetworkSettings.Networks "'"$NETWORK"'").IPAddress}}' "$CHALL_NAME")" \
    -v "$CERT_ROOT:/certberus:ro" \
    "$APACHE_IMG" sleep infinity >/dev/null \
    || { echo "apache container start failed"; exit 1; }

# IP of the apache container for DNS A record
APACHE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "'"$NETWORK"'").IPAddress}}' "$APACHE_NAME")
[[ -n "$APACHE_IP" ]] || { echo "cannot determine APACHE_IP"; exit 1; }

echo "### 7) Registering DNS A: $DOMAIN -> $APACHE_IP ###"
docker exec "$CHALL_NAME" sh -c "
    apt-get install -y curl >/dev/null 2>&1 || true
    wget -qO- --post-data='{\"host\":\"$DOMAIN.\",\"addresses\":[\"$APACHE_IP\"]}' \
        --header='Content-Type: application/json' \
        http://localhost:8055/add-a >/dev/null 2>&1 || \
    busybox wget -qO- --post-data=\"{\\\"host\\\":\\\"$DOMAIN.\\\",\\\"addresses\\\":[\\\"$APACHE_IP\\\"]}\" \
        --header=\"Content-Type: application/json\" \
        http://localhost:8055/add-a >/dev/null 2>&1
" 2>/dev/null || true
# Fallback: via host side
docker run --rm --network "$NETWORK" curlimages/curl:latest \
    -s -X POST "http://challtestsrv:8055/add-a" \
    -d "{\"host\":\"$DOMAIN.\",\"addresses\":[\"$APACHE_IP\"]}" >/dev/null 2>&1 || true

echo "### 8) Trust setup: pebble minica + roots/intermediates ###"
docker exec "$APACHE_NAME" bash -c "
    mkdir -p /usr/local/share/ca-certificates/pebble
    # minica.pem signs the management endpoint :15000
    docker_cp_minica='/test/certs/pebble.minica.pem'
" >/dev/null 2>&1
docker cp "$PEBBLE_NAME:/test/certs/pebble.minica.pem" "$WORK_DIR/minica.pem" 2>/dev/null || true
[[ -s "$WORK_DIR/minica.pem" ]] && \
    docker cp "$WORK_DIR/minica.pem" "$APACHE_NAME:/usr/local/share/ca-certificates/pebble/minica.crt" >/dev/null 2>&1

# download /roots/0 and /intermediates/0 from mgmt :15000
docker exec "$APACHE_NAME" bash -c "
    update-ca-certificates >/dev/null 2>&1 || true
    curl -sk --cacert /usr/local/share/ca-certificates/pebble/minica.crt \
         https://pebble:15000/roots/0 -o /usr/local/share/ca-certificates/pebble/root.crt
    curl -sk --cacert /usr/local/share/ca-certificates/pebble/minica.crt \
         https://pebble:15000/intermediates/0 -o /usr/local/share/ca-certificates/pebble/inter.crt
    update-ca-certificates >/dev/null 2>&1
"

echo "### 9) Installing certberus from source ###"
docker exec "$APACHE_NAME" bash -c "
    cp -r /certberus /tmp/cb && cd /tmp/cb && ./install.sh --prefix /usr/local
" >"$WORK_DIR/install.log" 2>&1 || { echo "install failed:"; tail -20 "$WORK_DIR/install.log"; exit 1; }

echo "### 10) Apache vhost :80 ONLY (certberus must add :443 stub itself) ###"
# IMPORTANT: we intentionally do not add :443 vhost. Stage_ensure_ssl_vhost should create it.
# This simulates a typical scenario 'sysadmin has only HTTP, certberus sets up HTTPS'.
docker exec "$APACHE_NAME" bash -c "
    cat > /etc/apache2/sites-available/test.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot /var/www/html
</VirtualHost>
EOF
    a2ensite test >/dev/null 2>&1
    service apache2 start >/dev/null 2>&1
" || { echo "apache start failed"; exit 1; }

echo "### 11) Running certberus auto against pebble:14000/dir ###"
# certberus auto must on its own:
#   - create :443 stub vhost (missing)
#   - wait for cert issuance (CB_POST_ISSUE_TIMEOUT)
#   - force graceful so the cert goes live
docker exec "$APACHE_NAME" bash -c "
    CB_POST_ISSUE_TIMEOUT=180 /usr/local/sbin/certberus auto \
        --webserver apache \
        --email admin@$DOMAIN \
        --domain $DOMAIN \
        --acme-url https://pebble:14000/dir \
        --yes
" >"$WORK_DIR/certberus.log" 2>&1
CB_RC=$?
[[ $CB_RC -eq 0 ]] || { echo "[WARN] certberus auto rc=$CB_RC, continuing to asserts"; tail -30 "$WORK_DIR/certberus.log"; }

# certberus already waited and called graceful. Just verify current state.
if docker exec "$APACHE_NAME" test -s /etc/apache2/md/domains/$DOMAIN/pubcert.pem 2>/dev/null; then
    ISSUED=1
else
    ISSUED=0
fi

# -------- ASSERTIONS --------
echo "### Assertions ###"

# A1) adapter in place
if docker exec "$APACHE_NAME" test -x /opt/certberus/mod_md-adapter.sh; then
    ok "adapter exists & exec"
else
    nok "adapter missing or not exec"
fi

# A2) adapter has 0750 root:www-data
PERM=$(docker exec "$APACHE_NAME" stat -c '%a %U:%G' /opt/certberus/mod_md-adapter.sh 2>/dev/null)
if [[ "$PERM" == "750 root:www-data" ]]; then
    ok "adapter perms 0750 root:www-data ($PERM)"
else
    nok "adapter perms expected '750 root:www-data', got '$PERM'"
fi

# A3) /opt/certberus and /etc/certberus traversable by www-data
PROBE=$(docker exec "$APACHE_NAME" sudo -u www-data test -x /opt/certberus && \
        docker exec "$APACHE_NAME" sudo -u www-data test -x /etc/certberus/hooks/installed.d \
        && echo OK)
if [[ "$PROBE" == "OK" ]]; then
    ok "/opt/certberus and /etc/certberus/hooks/installed.d traversable by www-data"
else
    nok "www-data cannot traverse /opt/certberus or /etc/certberus/hooks/installed.d"
fi

# A4) cert issued
if [[ "$ISSUED" == "1" ]]; then
    ok "cert issued (/etc/apache2/md/domains/$DOMAIN/pubcert.pem)"
else
    nok "cert NOT ISSUED after 90s"
    echo "    --- apache error.log (md): ---"
    docker exec "$APACHE_NAME" grep -E "md\[" /var/log/apache2/error.log 2>/dev/null | tail -10 | sed 's/^/    /'
    echo "    --- pebble log: ---"
    docker logs "$PEBBLE_NAME" 2>&1 | tail -10 | sed 's/^/    /'
fi

# A5) cert is from Pebble (not snakeoil)
if [[ "$ISSUED" == "1" ]]; then
    ISSUER=$(docker exec "$APACHE_NAME" bash -c "
        openssl x509 -in /etc/apache2/md/domains/$DOMAIN/pubcert.pem -noout -issuer
    " 2>/dev/null)
    if echo "$ISSUER" | grep -qi "Pebble"; then
        ok "issuer=Pebble ($ISSUER)"
    else
        nok "issuer is not Pebble: $ISSUER"
    fi
fi

# A6) MDMessageCMD adapter was called on 'installed' event
EVENT_LOG=$(docker exec "$APACHE_NAME" cat /var/log/certberus/mod_md-events.log 2>/dev/null)
if echo "$EVENT_LOG" | grep -q "event=installed domain=$DOMAIN"; then
    ok "adapter logged event=installed domain=$DOMAIN"
else
    nok "adapter did NOT log event=installed (possibly 255 perm bug reappeared)"
    echo "$EVENT_LOG" | tail -10 | sed 's/^/    /'
fi

# A7) graceful reload occurred after installed
if docker exec "$APACHE_NAME" grep -q "AH00493: SIGUSR1 received" /var/log/apache2/error.log 2>/dev/null; then
    ok "apache graceful reload detected in error.log"
else
    nok "apache graceful reload NOT detected"
fi

# A8) :443 serves Pebble cert -- NO manual reload, certberus already did it
if [[ "$ISSUED" == "1" ]]; then
    SERVED=$(docker exec "$APACHE_NAME" bash -c "
        echo | openssl s_client -connect 127.0.0.1:443 -servername $DOMAIN 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null
    ")
    if echo "$SERVED" | grep -qi "Pebble"; then
        ok ":443 serves Pebble cert ($SERVED)"
    else
        nok ":443 does not serve Pebble cert: '$SERVED'"
    fi

    HTTP=$(docker exec "$APACHE_NAME" curl -sk -o /dev/null -w "%{http_code}" \
        https://$DOMAIN/ 2>/dev/null)
    if [[ "$HTTP" == "200" ]]; then
        ok "https://$DOMAIN/ returns 200"
    else
        nok "https://$DOMAIN/ returns '$HTTP' (expected 200)"
    fi
fi

# A9) certberus log contains 'graceful OK' from post_issue_activate
if grep -qE "Second.*graceful|Cert in staging|already in ManagedDomains" "$WORK_DIR/certberus.log" 2>/dev/null; then
    ok "post_issue_activate stage completed (second graceful)"
else
    nok "post_issue_activate stage NOT recorded in log"
fi

# A10) certberus created :443 stub vhost on its own (test.conf had only :80)
if docker exec "$APACHE_NAME" test -f /etc/apache2/sites-enabled/certberus-ssl.conf; then
    ok "certberus created stub :443 vhost (certberus-ssl.conf)"
else
    nok "certberus did NOT create stub :443 vhost"
fi

echo
echo "### Result: PASS=$PASS  FAIL=$FAIL ###"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
