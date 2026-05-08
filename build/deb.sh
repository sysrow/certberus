#!/bin/bash
# build/deb.sh - runs INSIDE debian:12 container
# Env: VERSION, /src (read-only sources), /dist (artifact output)
set -euo pipefail

VERSION="${VERSION:?VERSION env is not set}"
SRC="/src"
OUT="/dist"
PKGROOT="$(mktemp -d)"
trap "rm -rf '$PKGROOT'" EXIT

# Instaluj build deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y --no-install-recommends dpkg-dev fakeroot >/dev/null

install -d -m 0755 "$PKGROOT/DEBIAN"
install -d -m 0755 "$PKGROOT/usr/sbin"
install -d -m 0755 "$PKGROOT/usr/lib/certberus"
install -d -m 0755 "$PKGROOT/usr/lib/certberus/webservers"
install -d -m 0755 "$PKGROOT/usr/share/certberus/config"
install -d -m 0755 "$PKGROOT/usr/share/certberus/hooks"
install -d -m 0755 "$PKGROOT/usr/share/doc/certberus"
install -d -m 0755 "$PKGROOT/etc/certberus"
install -d -m 0755 "$PKGROOT/etc/certberus/hooks"
install -d -m 0755 "$PKGROOT/etc/logrotate.d"

# Bin - patch CB_LIB_DIR lookup from /usr/local/lib to /usr/lib
install -m 0755 "$SRC/bin/certberus" "$PKGROOT/usr/sbin/certberus"
sed -i 's|/usr/local/lib/certberus|/usr/lib/certberus|g' "$PKGROOT/usr/sbin/certberus"

# Lib
for f in common.sh os.sh dns.sh firewall.sh hooks.sh discover.sh preflight.sh scan.sh; do
    install -m 0644 "$SRC/lib/$f" "$PKGROOT/usr/lib/certberus/$f"
done

# Webservers
for f in apache-md.sh apache-md-eab.sh nginx-certbot.sh tomcat-certbot.sh; do
    install -m 0755 "$SRC/webservers/$f" "$PKGROOT/usr/lib/certberus/webservers/$f"
done

# Config examples
install -m 0644 "$SRC/config/config.env.example"   "$PKGROOT/usr/share/certberus/config/"
install -m 0644 "$SRC/config/advanced.env.example" "$PKGROOT/usr/share/certberus/config/"

# Hooks examples
cp -R "$SRC/hooks/examples" "$PKGROOT/usr/share/certberus/hooks/"
install -m 0644 "$SRC/hooks/README.md" "$PKGROOT/usr/share/certberus/hooks/README.md"

# Doc
install -m 0644 "$SRC/README.md" "$PKGROOT/usr/share/doc/certberus/README.md" 2>/dev/null || true

# Changelog (required by Debian policy)
cat > "$PKGROOT/usr/share/doc/certberus/changelog.Debian" <<EOF
certberus ($VERSION) stable; urgency=medium

  * Release $VERSION

 -- certberus maintainers <root@localhost>  $(date -R)
EOF
gzip -9n "$PKGROOT/usr/share/doc/certberus/changelog.Debian"

# Logrotate
cat > "$PKGROOT/etc/logrotate.d/certberus" <<'EOF'
/var/log/certberus/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

# --- DEBIAN/control ---
INSTALLED_SIZE=$(du -sk "$PKGROOT" --exclude=DEBIAN | awk '{print $1}')
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: certberus
Version: $VERSION
Section: net
Priority: optional
Architecture: all
Maintainer: certberus maintainers <root@localhost>
Installed-Size: $INSTALLED_SIZE
Depends: bash (>= 4.0), coreutils, grep, sed, gawk, openssl, curl, ca-certificates, bind9-dnsutils | dnsutils
Recommends: certbot
Suggests: libapache2-mod-md, python3-certbot-apache, python3-certbot-nginx
Homepage: https://github.com/Tristram1337/temp
Description: Unified ACME certificate deployment for Apache/nginx/Tomcat
 certberus is a bash-based orchestrator for issuing and deploying TLS
 certificates from Let's Encrypt, HARICA and ZeroSSL on Apache (mod_md),
 nginx (certbot) and Tomcat (certbot). It provides preflight validation,
 domain discovery, hook scripts and unified logging across distributions.
EOF

cat > "$PKGROOT/DEBIAN/conffiles" <<EOF
/etc/logrotate.d/certberus
EOF

cat > "$PKGROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

ETC=/etc/certberus
STATE=/var/lib/certberus
LOGDIR=/var/log/certberus
BACKUPDIR=/var/backups/certberus

mkdir -p "$ETC" "$ETC/hooks" "$STATE" "$LOGDIR" "$BACKUPDIR"

if [ ! -f "$ETC/config.env" ]; then
    install -m 0640 /usr/share/certberus/config/config.env.example "$ETC/config.env"
fi
if [ ! -f "$ETC/advanced.env" ]; then
    install -m 0640 /usr/share/certberus/config/advanced.env.example "$ETC/advanced.env"
fi

for ev in pre-install post-install pre-snapshot post-snapshot \
          pre-issue post-issue pre-deploy post-deploy \
          pre-reload post-reload on-failure on-rollback \
          renewing renewed installed expiring errored \
          ocsp-renewed ocsp-errored challenge-setup; do
    mkdir -p "$ETC/hooks/$ev.d"
    chmod 0755 "$ETC/hooks/$ev.d"
done

if [ ! -f "$ETC/hooks/README.md" ]; then
    cp /usr/share/certberus/hooks/README.md "$ETC/hooks/README.md" 2>/dev/null || true
fi

[ -L "$ETC/hooks/examples" ] || ln -sfn /usr/share/certberus/hooks/examples "$ETC/hooks/examples"

chmod 0755 "$ETC" "$ETC/hooks" "$STATE" "$LOGDIR" "$BACKUPDIR"

echo "certberus installed."
echo "  Config:     $ETC/config.env"
echo "  First run:  sudo certberus install"

exit 0
POSTINST
chmod 0755 "$PKGROOT/DEBIAN/postinst"

cat > "$PKGROOT/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
exit 0
PRERM
chmod 0755 "$PKGROOT/DEBIAN/prerm"

cat > "$PKGROOT/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
case "$1" in
    purge)
        rm -rf /var/lib/certberus /var/log/certberus /var/backups/certberus
        ;;
esac
exit 0
POSTRM
chmod 0755 "$PKGROOT/DEBIAN/postrm"

fakeroot dpkg-deb --build -Zgzip "$PKGROOT" "$OUT/certberus_${VERSION}_all.deb"

# Basic lint (pipe to sed so SIGPIPE does not kill on head)
dpkg-deb --info "$OUT/certberus_${VERSION}_all.deb" | sed -n '1,20p'
echo "--- Contents (first 20) ---"
dpkg-deb --contents "$OUT/certberus_${VERSION}_all.deb" | sed -n '1,20p'

echo "[OK] .deb built"
