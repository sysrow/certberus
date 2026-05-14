#!/bin/bash
# tests/unit/test-apache-md-ssl-comment.sh
#
# Regression test for the bug where mod_md failed ACME because the user vhost
# still had hardcoded SSLCertificateFile/SSLCertificateKeyFile pointing to a
# previous certbot path. tls-alpn-01 needs to swap the cert during the TLS
# handshake; an explicit path pins Apache to a stale cert and the challenge
# returns "invalid". stage_fix_ssl_vhosts must comment those directives out
# (inside the :443 block only) and leave a .bak_$ts snapshot.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/env.sh"

SANDBOX=$(t_mktempdir)
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"

export CB_APACHE_CONF_DIR="$SANDBOX/sites-available"
export CB_APACHE_ENABLED_DIR="$SANDBOX/sites-enabled"
mkdir -p "$CB_APACHE_CONF_DIR" "$CB_APACHE_ENABLED_DIR"

VHOST="$CB_APACHE_CONF_DIR/oidc-civ.conf"
cat >"$VHOST" <<'EOF'
<VirtualHost *:443>
    ServerName oidc.example.com

    SSLEngine on
    SSLCertificateFile      /etc/letsencrypt/live/oidc.example.com/fullchain.pem
    SSLCertificateKeyFile   /etc/letsencrypt/live/oidc.example.com/privkey.pem

    DocumentRoot /var/www/html
</VirtualHost>

<VirtualHost *:80>
    ServerName oidc.example.com
    DocumentRoot /var/www/html
    RewriteEngine on
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF

# Source-time defaults for apache-md.sh
export CB_OS_ID=debian
export CB_OS_VERSION=13
export CB_PKG_MGR=apt
export CB_DRY_RUN=0
export CB_ASSUME_YES=1
export CB_AUTO_ROLLBACK=0

# Empty config files so cb_load_config is a no-op
: > "$CB_CONFIG_FILE"
: > "$CB_ADVANCED_FILE"

# Source apache-md.sh WITHOUT triggering its trailing `main "$@"` invocation.
# We want the function definitions only (stage_fix_ssl_vhosts in particular).
# shellcheck disable=SC1091
source <(sed '$d' "$CB_REPO_ROOT/webservers/apache-md.sh")

# Bypass directory-walking: feed our single test vhost
get_enabled_sites() { echo "$VHOST"; }

# CB_VALID_DOMAINS_FILE was mktemp'd by apache-md.sh; reuse it
echo "oidc.example.com" > "$CB_VALID_DOMAINS_FILE"

t_info "Running stage_fix_ssl_vhosts against vhost with certbot SSL paths"
stage_fix_ssl_vhosts >/dev/null 2>&1 || true

content=$(cat "$VHOST")

# The active directives must be gone; the commented form must be present.
assert_not_contains "$content" $'\n    SSLCertificateFile      /etc/letsencrypt' "active SSLCertificateFile removed"
assert_not_contains "$content" $'\n    SSLCertificateKeyFile   /etc/letsencrypt' "active SSLCertificateKeyFile removed"
assert_contains    "$content" "# certberus: managed by mod_md (was): SSLCertificateFile"    "SSLCertificateFile commented with marker"
assert_contains    "$content" "# certberus: managed by mod_md (was): SSLCertificateKeyFile" "SSLCertificateKeyFile commented with marker"

# The :80 vhost should be untouched (no SSL directives there anyway, but the
# RewriteRule must survive verbatim).
assert_contains "$content" "RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/" ":80 rewrite preserved"

# Backup file must exist
shopt -s nullglob
bak=("$VHOST".bak_*)
shopt -u nullglob
if (( ${#bak[@]} > 0 )); then
    t_pass "backup file created (${bak[0]##*/})"
else
    t_fail "no .bak_* backup created"
fi

t_summary
