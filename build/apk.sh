#!/bin/sh
# build/apk.sh - runs INSIDE alpine:3.20 container
# Env: VERSION, /src (ro), /dist (rw)
set -eu

VERSION="${VERSION:?VERSION env is not set}"
SRC="/src"
OUT="/dist"

apk update -q >/dev/null
apk add --no-cache -q alpine-sdk sudo >/dev/null

# abuild requires a non-root user and signing key
adduser -D -G abuild builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
su - builder -c "abuild-keygen -a -n -q"

# Prepare build dir (must be owned by builder)
BUILD="/home/builder/certberus"
mkdir -p "$BUILD"

# Source files as tarball
STAGE="/tmp/stage/certberus-$VERSION"
mkdir -p "$STAGE"
cp -R "$SRC/bin" "$SRC/lib" "$SRC/webservers" "$SRC/config" "$SRC/hooks" "$STAGE/"
cp "$SRC/install.sh" "$STAGE/" 2>/dev/null || true
cp "$SRC/README.md"  "$STAGE/" 2>/dev/null || true
tar --owner=0 --group=0 --numeric-owner \
    --sort=name --mtime='2024-01-01 00:00:00 UTC' \
    -czf "$BUILD/certberus-$VERSION.tar.gz" \
    -C /tmp/stage "certberus-$VERSION"

# APKBUILD
cat > "$BUILD/APKBUILD" <<APKBUILD
# Maintainer: Certberus Maintainers <certberus@example.com>
pkgname=certberus
pkgver=$VERSION
pkgrel=0
pkgdesc="Unified ACME certificate deployment for Apache/nginx/Tomcat"
url="https://github.com/Tristram1337/temp"
arch="noarch"
license="MIT"
depends="bash coreutils grep sed gawk openssl curl ca-certificates bind-tools"
source="\$pkgname-\$pkgver.tar.gz"
builddir="\$srcdir/\$pkgname-\$pkgver"
options="!check"

package() {
    cd "\$builddir"
    install -d -m 0755 "\$pkgdir"/usr/sbin
    install -d -m 0755 "\$pkgdir"/usr/lib/certberus/webservers
    install -d -m 0755 "\$pkgdir"/usr/share/certberus/config
    install -d -m 0755 "\$pkgdir"/usr/share/certberus/hooks
    install -d -m 0755 "\$pkgdir"/etc/certberus/hooks
    install -d -m 0755 "\$pkgdir"/etc/logrotate.d
    install -d -m 0755 "\$pkgdir"/var/lib/certberus
    install -d -m 0755 "\$pkgdir"/var/log/certberus

    install -m 0755 bin/certberus "\$pkgdir"/usr/sbin/certberus
    sed -i 's|/usr/local/lib/certberus|/usr/lib/certberus|g' "\$pkgdir"/usr/sbin/certberus

    for f in common.sh os.sh dns.sh firewall.sh hooks.sh discover.sh preflight.sh scan.sh; do
        install -m 0644 lib/\$f "\$pkgdir"/usr/lib/certberus/\$f
    done
    for f in apache-md.sh apache-md-eab.sh nginx-certbot.sh tomcat-certbot.sh; do
        install -m 0755 webservers/\$f "\$pkgdir"/usr/lib/certberus/webservers/\$f
    done

    install -m 0644 config/config.env.example   "\$pkgdir"/usr/share/certberus/config/
    install -m 0644 config/advanced.env.example "\$pkgdir"/usr/share/certberus/config/
    install -m 0640 config/config.env.example   "\$pkgdir"/etc/certberus/config.env
    install -m 0640 config/advanced.env.example "\$pkgdir"/etc/certberus/advanced.env

    cp -R hooks/examples "\$pkgdir"/usr/share/certberus/hooks/
    install -m 0644 hooks/README.md "\$pkgdir"/usr/share/certberus/hooks/README.md

    cat > "\$pkgdir"/etc/logrotate.d/certberus <<'LOGR'
/var/log/certberus/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGR

    # Hook event dirs
    for ev in pre-install post-install pre-snapshot post-snapshot \\
              pre-issue post-issue pre-deploy post-deploy \\
              pre-reload post-reload on-failure on-rollback \\
              renewing renewed installed expiring errored \\
              ocsp-renewed ocsp-errored challenge-setup; do
        install -d -m 0755 "\$pkgdir"/etc/certberus/hooks/\$ev.d
    done
}
APKBUILD

chown -R builder:abuild "$BUILD"

# Build - needs checksums + own key.
# abuild -r (rootbld/index) may fail on trust signature, but .apk is already built
# -> tolerujeme non-zero exit, detekce uspechu je pres find
set +e
su - builder -c "cd $BUILD && abuild checksum && abuild -F -r"
set -e

# Output APK is in /home/builder/packages/certberus/noarch/
APK_OUT=$(find /home/builder/packages -name 'certberus-*.apk' 2>/dev/null | head -1)
[ -n "$APK_OUT" ] || { echo "[ERR] APK not found - build actually failed"; exit 1; }
cp "$APK_OUT" "$OUT/certberus-${VERSION}-r0.apk"

# Info
apk info "$OUT/certberus-${VERSION}-r0.apk" 2>/dev/null | head -20 || true

echo "[OK] .apk built"
