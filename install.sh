#!/bin/bash
# certberus install.sh - installs certberus into the system
# Usage:   sudo ./install.sh [--prefix /usr/local] [--uninstall]
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
ETC="${ETC:-/etc/certberus}"
LOG_DIR="${LOG_DIR:-/var/log/certberus}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/certberus}"
STATE_DIR="${STATE_DIR:-/var/lib/certberus}"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) shift; PREFIX="$1" ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)
            cat <<EOF
Usage: install.sh [--prefix /usr/local] [--uninstall]
  --prefix    Install location (default /usr/local)
  --uninstall Uninstall (does not delete config or logs)
EOF
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if (( UNINSTALL )); then
    echo "Uninstalling certberus..."
    rm -f "$PREFIX/sbin/certberus"
    rm -rf "$PREFIX/lib/certberus"
    echo "Config in $ETC and logs in $LOG_DIR preserved."
    echo "For complete removal:  rm -rf $ETC $LOG_DIR $BACKUP_DIR $STATE_DIR"
    exit 0
fi

echo "=== Certberus installer ==="
echo "Prefix:   $PREFIX"
echo "Etc:      $ETC"
echo "Log:      $LOG_DIR"
echo "Backup:   $BACKUP_DIR"
echo "State:    $STATE_DIR"
echo

# Directories
install -d -m 0755 "$PREFIX/sbin"
install -d -m 0755 "$PREFIX/lib/certberus"
install -d -m 0755 "$PREFIX/lib/certberus/webservers"
install -d -m 0755 "$ETC" "$ETC/hooks"
install -d -m 0755 "$LOG_DIR" "$BACKUP_DIR" "$STATE_DIR"

# Hook event directories
for ev in pre-install post-install pre-snapshot post-snapshot \
          pre-issue post-issue pre-deploy post-deploy \
          pre-reload post-reload on-failure on-rollback \
          renewing renewed installed expiring errored \
          ocsp-renewed ocsp-errored challenge-setup; do
    install -d -m 0755 "$ETC/hooks/${ev}.d"
done

# Lib
echo "Installing lib/"
for f in common.sh os.sh dns.sh firewall.sh hooks.sh discover.sh preflight.sh; do
    install -m 0644 "$SRC/lib/$f" "$PREFIX/lib/certberus/$f"
done

# Webservers
echo "Installing webservers/"
for f in apache-md.sh apache-md-eab.sh nginx-certbot.sh tomcat-certbot.sh certbot-only.sh jetty-certbot.sh caddy.sh; do
    install -m 0755 "$SRC/webservers/$f" "$PREFIX/lib/certberus/webservers/$f"
done

# Bin
echo "Installing bin/certberus"
install -m 0755 "$SRC/bin/certberus" "$PREFIX/sbin/certberus"

# Config (do not overwrite existing)
if [[ ! -f "$ETC/config.env" ]]; then
    echo "Installing $ETC/config.env"
    install -m 0640 "$SRC/config/config.env.example" "$ETC/config.env"
else
    echo "Config $ETC/config.env already exists — keeping it."
fi
if [[ ! -f "$ETC/advanced.env" ]]; then
    install -m 0640 "$SRC/config/advanced.env.example" "$ETC/advanced.env"
fi

# Example hooks
echo "Installing example hooks to $ETC/hooks/examples/"
install -d -m 0755 "$ETC/hooks/examples"
cp -R "$SRC/hooks/examples/." "$ETC/hooks/examples/" 2>/dev/null || true
find "$ETC/hooks/examples" -type f -name '*.sh.example' -exec chmod 0644 {} \;
install -m 0644 "$SRC/hooks/README.md" "$ETC/hooks/README.md"

# Syslog/logrotate (optional)
if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/certberus <<EOF
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
    echo "Logrotate: /etc/logrotate.d/certberus"
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  Certberus installed."
echo
echo "  Next steps:"
echo "    1. Edit configuration:   \$EDITOR $ETC/config.env"
echo "    2. Run the wizard:       certberus install"
echo "    3. Verify environment:   certberus doctor"
echo "    4. Check status:         certberus status"
echo
echo "  Documentation:  $ETC/hooks/README.md"
echo "═══════════════════════════════════════════════════════════════"
