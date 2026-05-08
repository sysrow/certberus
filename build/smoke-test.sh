#!/bin/bash
# build/smoke-test.sh
# Post-build: install each artifact in the corresponding distro and run `certberus version`.
# Quick sanity check that packages are at least runnable.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DIST="$REPO_ROOT/dist"
VERSION="$(cat "$REPO_ROOT/build/VERSION" | tr -d '[:space:]')"

FAIL=0
PASS=0
SKIP=0

check_docker() {
    command -v docker >/dev/null 2>&1 || { echo "Docker is missing"; exit 2; }
    docker info >/dev/null 2>&1 || { echo "Docker daemon is not running"; exit 2; }
}

smoke() {
    local name="$1" image="$2" install_cmd="$3" artifact="$4" shell="${5:-bash}"
    echo ""
    echo "=== $name ($image) ==="
    if [[ ! -f "$DIST/$artifact" ]]; then
        echo "  [SKIP] $artifact does not exist"
        SKIP=$((SKIP+1))
        return 0
    fi
    local out
    out=$(docker run --rm --network=host \
        -v "$DIST:/dist:ro" \
        "$image" \
        "$shell" -c "$install_cmd && certberus version 2>&1 || certberus --help 2>&1 | head -3" 2>&1)
    if echo "$out" | grep -qE "certberus v?$VERSION|v$VERSION - unified"; then
        echo "  [PASS] install + run OK"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] install or run failed"
        echo "$out" | tail -15 | sed 's/^/    | /'
        FAIL=$((FAIL+1))
    fi
}

check_docker

# Tarball (on Debian)
smoke "tarball" "debian:12" \
    "apt-get update -qq && apt-get install -qq -y --no-install-recommends bash coreutils openssl ca-certificates dnsutils curl >/dev/null && \
     tar xf /dist/certberus-$VERSION.tar.gz -C /tmp && cd /tmp/certberus-$VERSION && ./install.sh >/dev/null 2>&1 && \
     /usr/local/sbin/certberus version" \
    "certberus-$VERSION.tar.gz"

# DEB on Debian 12
smoke ".deb (debian:12)" "debian:12" \
    "apt-get update -qq >/dev/null && apt-get install -qq -y /dist/certberus_${VERSION}_all.deb >/dev/null && certberus version" \
    "certberus_${VERSION}_all.deb"

# DEB on Ubuntu 24.04
smoke ".deb (ubuntu:24.04)" "ubuntu:24.04" \
    "apt-get update -qq >/dev/null && apt-get install -qq -y /dist/certberus_${VERSION}_all.deb >/dev/null && certberus version" \
    "certberus_${VERSION}_all.deb"

# RPM on Rocky 8 (noarch install - works on EL8/9/10)
# Note: Rocky 9 requires x86-64-v2 CPU, skip if host lacks it.
smoke ".rpm (rockylinux:8)" "rockylinux:8" \
    "dnf install -q -y /dist/certberus-${VERSION}-1.noarch.rpm >/dev/null 2>&1 && certberus version" \
    "certberus-${VERSION}-1.noarch.rpm"

# RPM on Rocky 9 - skip if CPU does not support x86-64-v2 (works on modern hw in CI)
if docker run --rm rockylinux:9 true 2>/dev/null; then
    smoke ".rpm (rockylinux:9)" "rockylinux:9" \
        "dnf install -q -y /dist/certberus-${VERSION}-1.noarch.rpm >/dev/null 2>&1 && certberus version" \
        "certberus-${VERSION}-1.noarch.rpm"
else
    echo ""
    echo "=== .rpm (rockylinux:9) ==="
    echo "  [SKIP] host CPU does not support x86-64-v2 (passes in CI/GitHub Actions)"
fi

# RPM on Fedora
smoke ".rpm (fedora:40)" "fedora:40" \
    "dnf install -q -y /dist/certberus-${VERSION}-1.noarch.rpm >/dev/null 2>&1 && certberus version" \
    "certberus-${VERSION}-1.noarch.rpm"

# APK on Alpine - Alpine does not have bash preinstalled, use sh and install bash as dep
smoke ".apk (alpine:3.20)" "alpine:3.20" \
    "apk add --allow-untrusted -q /dist/certberus-${VERSION}-r0.apk >/dev/null 2>&1 && certberus version" \
    "certberus-${VERSION}-r0.apk" \
    "sh"

echo ""
echo "======================================"
echo "  Smoke test: $PASS pass, $FAIL fail, $SKIP skip"
echo "======================================"
exit $FAIL
