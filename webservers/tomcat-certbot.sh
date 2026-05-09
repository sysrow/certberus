#!/bin/bash
# certberus/webservers/tomcat-certbot.sh
# Tomcat 9+ + certbot + Let's Encrypt / HARICA / ZeroSSL
#
# Strategy:
#   1. Detect Tomcat instance (systemd unit, CATALINA_BASE, conf directory)
#   2. Detect port-80 strategy: iptables redirect / webroot via Tomcat Context
#      / reverse-proxy (then we stop - the proxy should handle the cert)
#   3. certbot webroot (into a directory served by Tomcat)
#   4. Copy cert to a keystore-friendly location (Tomcat has no access to /etc/letsencrypt/)
#   5. Inject Connector with SSLHostConfig + Certificate (PEM format, Tomcat 8.5+)
#   6. Atomic reload: if restart fails, rollback to previous cert
#
# LIMITATIONS:
#   - We support Tomcat 9, 10, 11 (NIO/NIO2 connector, PEM cert format)
#   - Tomcat 8.5 and older (JKS keystore) are intentionally not supported
#   - APR connector (OpenSSL) is detected and warned about, but not configured
#
set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
_LIB_DIR="${CB_LIB_DIR:-$(dirname "$_SCRIPT_DIR")/lib}"
if [[ ! -f "$_LIB_DIR/common.sh" ]]; then
    for d in /usr/local/lib/certberus /usr/lib/certberus /opt/certberus/lib; do
        [[ -f "$d/common.sh" ]] && { _LIB_DIR="$d"; break; }
    done
fi
# shellcheck disable=SC1091
source "$_LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$_LIB_DIR/os.sh"
# shellcheck disable=SC1091
source "$_LIB_DIR/dns.sh"
# shellcheck disable=SC1091
source "$_LIB_DIR/firewall.sh"
# shellcheck disable=SC1091
source "$_LIB_DIR/hooks.sh"
# shellcheck disable=SC1091
source "$_LIB_DIR/preflight.sh"
cb_load_config

: "${CB_TOMCAT_SERVICE:=auto}"
: "${CB_TOMCAT_HOME:=auto}"
: "${CB_TOMCAT_PORT80_STRATEGY:=iptables}"  # iptables | webroot | proxy
: "${CB_TOMCAT_ACME_WEBROOT:=}"
: "${CB_CERTBOT_HOOK_DIR:=/etc/letsencrypt/renewal-hooks/deploy}"
: "${CB_TOMCAT_SSL_DIR:=/etc/tomcat/ssl}"    # where we copy PEM, Tomcat has read access

CB_CA="${CB_CA:-letsencrypt}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_EMAIL="${CB_EMAIL:-}"
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"
CB_TOMCAT_PORT80_STRATEGY_CLI=0

TOMCAT_VERSION=""
TOMCAT_SERVICE=""
TOMCAT_USER=""
TOMCAT_CONF_DIR=""
TOMCAT_SERVER_XML=""
TOMCAT_ACME_WEBROOT=""   # if webroot strategy
VALID_DOMAINS=()

usage() {
    cat <<USAGE
tomcat-certbot.sh - Tomcat 9+ + certbot

Usage: $0 [OPTIONS]

  -t, --staging        Staging CA
  -y, --yes            Non-interactive
  -n, --dry-run        Simulation
  -v, --verbose        Debug
      --domain D       Domain (repeatable)
      --email E        Email
      --ca NAME        letsencrypt | harica | zerossl
      --acme-url URL   Custom ACME directory URL
      --webroot DIR    ACME webroot for webroot/proxy strategy
      --eab-kid KID
      --eab-hmac HMAC
      --port80 STRAT   iptables | webroot | proxy (default: iptables)
      --no-firewall    Never automatically modify firewall
      --open-firewall  Explicitly allow firewall mutations (including HARICA)
      --set CB_X=Y     Advanced override of any CB_* option
  -h, --help

Requirements:
  - Tomcat 9, 10, or 11 (managed via systemd)
  - Port 80 open from internet (or iptables redirect)
  - Domains point via DNS record to this machine
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -t|--staging) CB_STAGING=1 ;;
            -y|--yes) CB_ASSUME_YES=1 ;;
            -n|--dry-run) CB_DRY_RUN=1 ;;
            -v|--verbose) CB_VERBOSE=1 ;;
            --domain) shift; CB_DOMAINS="$CB_DOMAINS $1" ;;
            --email) shift; CB_EMAIL="$1" ;;
            --ca) shift; CB_CA="$1" ;;
            --acme-url) shift; CB_ACME_URL="$1" ;;
            --webroot) [[ $# -ge 2 ]] || cb_die "--webroot requires a value"; shift; CB_TOMCAT_ACME_WEBROOT="$1" ;;
            --eab-kid) shift; CB_EAB_KID="$1" ;;
            --eab-hmac) shift; CB_EAB_HMAC="$1" ;;
            --port80) shift; CB_TOMCAT_PORT80_STRATEGY="$1"; CB_TOMCAT_PORT80_STRATEGY_CLI=1 ;;
            --no-firewall) cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=0" ;;
            --open-firewall)
                cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=1"
                cb_apply_cli_set "CB_HARICA_FIREWALL_AUTO_OPEN=1"
                ;;
            --set) [[ $# -ge 2 ]] || cb_die "--set requires a value CB_NAME=value"; shift; cb_apply_cli_set "$1" ;;
            *) cb_warn "Unknown argument: $1" ;;
        esac
        shift
    done
}

# ============================================================================
_CB_TOMCAT_ORIG_ROOT_XML=""

_cb_tomcat_restore_root_context() {
    local ctx_dir="$TOMCAT_CONF_DIR/Catalina/localhost"
    local root_xml="$ctx_dir/ROOT.xml"
    [[ -f "$root_xml" ]] || return 0
    if grep 'certberus' "$root_xml" 2>/dev/null || grep -q 'docBase="/var/www/acme"' "$root_xml" 2>/dev/null; then >/dev/null
        if [[ -n "$_CB_TOMCAT_ORIG_ROOT_XML" && -f "$_CB_TOMCAT_ORIG_ROOT_XML" ]]; then
            mv "$_CB_TOMCAT_ORIG_ROOT_XML" "$root_xml"
            cb_ok "ROOT.xml restored from backup"
        else
            rm -f "$root_xml"
            cb_ok "Temporary ACME ROOT.xml removed"
        fi
    fi
}

# Detect Tomcat instance
# ============================================================================
stage_prepare() {
    cb_banner "Certberus / Tomcat 9+ / certbot"
    cb_require_root
    cb_hook_context tomcat ""
    mkdir -p "$CB_LOG_DIR" "$CB_STATE_DIR" "$CB_CERTBOT_HOOK_DIR" 2>/dev/null
    cb_run_hooks pre-install
}

stage_detect_tomcat() {
    cb_sep
    cb_log "Detecting Tomcat instance"

    # 1. Find systemd unit
    if [[ "$CB_TOMCAT_SERVICE" == "auto" ]]; then
        local candidates=()
        while IFS= read -r u; do
            candidates+=("$u")
        done < <(systemctl list-unit-files 2>/dev/null | awk '/^tomcat[0-9]*\.service/ {print $1}' | sed 's/\.service$//')
        if (( ${#candidates[@]} == 0 )); then
            cb_die "No tomcat systemd unit found. Install tomcat9/10/11."
        elif (( ${#candidates[@]} == 1 )); then
            TOMCAT_SERVICE="${candidates[0]}"
        else
            cb_log "Multiple Tomcat instances found: ${candidates[*]}"
            if cb_has_tty && [[ "$CB_ASSUME_YES" != "1" ]]; then
                local PS3="Choose [1-${#candidates[@]}]: "
                select s in "${candidates[@]}"; do
                    [[ -n "$s" ]] && { TOMCAT_SERVICE="$s"; break; }
                done < /dev/tty
            else
                TOMCAT_SERVICE="${candidates[0]}"
                cb_warn "Selecting default: $TOMCAT_SERVICE"
            fi
        fi
    else
        TOMCAT_SERVICE="$CB_TOMCAT_SERVICE"
    fi
    cb_ok "Tomcat service: $TOMCAT_SERVICE"

    # 2. Version
    local version_num
    version_num=$(echo "$TOMCAT_SERVICE" | grep -m1 -oE '[0-9]+')
    if [[ -n "$version_num" ]]; then
        TOMCAT_VERSION="$version_num"
    else
        # Try to detect from tomcat binary
        local tomcat_home
        tomcat_home=$(systemctl show "$TOMCAT_SERVICE" -p Environment 2>/dev/null | grep -m1 -oE 'CATALINA_HOME=[^ ]+' | cut -d= -f2)
        [[ -n "$tomcat_home" && -x "$tomcat_home/bin/version.sh" ]] && \
            TOMCAT_VERSION=$("$tomcat_home/bin/version.sh" 2>/dev/null | awk '/Server version:/{for(i=1;i<=NF;i++) if(match($i,/[0-9]+/)){print substr($i,RSTART,RLENGTH); exit}}')
    fi
    cb_log "Tomcat version: ${TOMCAT_VERSION:-unknown}"

    if [[ -n "$TOMCAT_VERSION" ]] && (( TOMCAT_VERSION < 9 )); then
        cb_die "Tomcat $TOMCAT_VERSION is not supported. Minimum: 9."
    fi

    # 3. Conf dir
    for d in \
        "/etc/tomcat${TOMCAT_VERSION}" \
        "/etc/$TOMCAT_SERVICE" \
        "/etc/tomcat"; do
        if [[ -d "$d" && -f "$d/server.xml" ]]; then
            TOMCAT_CONF_DIR="$d"
            TOMCAT_SERVER_XML="$d/server.xml"
            break
        fi
    done
    [[ -z "$TOMCAT_CONF_DIR" ]] && cb_die "Config directory not found ($TOMCAT_SERVICE)"
    cb_ok "Conf: $TOMCAT_CONF_DIR"

    # 4. User
    TOMCAT_USER=$(systemctl show "$TOMCAT_SERVICE" -p User 2>/dev/null | cut -d= -f2)
    [[ -z "$TOMCAT_USER" ]] && TOMCAT_USER="tomcat"
    cb_ok "User: $TOMCAT_USER"

    # 5. Warning about APR
    if grep -E 'AprLifecycleListener' "$TOMCAT_SERVER_XML" 2>/dev/null && \ >/dev/null
       grep -E 'protocol=".*Apr' "$TOMCAT_SERVER_XML" 2>/dev/null; then >/dev/null
        cb_warn "APR/OpenSSL connector detected - certberus only configures NIO/NIO2."
        cb_warn "You must manually adjust the APR connector (different attributes)."
    fi
}

stage_install_packages() {
    cb_sep
    local need=()
    cb_pkg_installed certbot || need+=(certbot)
    # dnsutils (dig) is not strictly needed - getent handles A/AAAA; CAA is just a warning
    command -v python3 >/dev/null 2>&1 || need+=(python3)  # for safe XML manipulation (not replaceable by sed/awk)
    if (( ${#need[@]} > 0 )); then
        cb_log "Missing: ${need[*]}"
        cb_ask_yn "Install?" "Y/n" || cb_die "Aborting"
        cb_pkg_install "${need[@]}" || cb_die "Installation failed"
    fi
    cb_run_hooks post-install
}

stage_snapshot() {
    cb_sep
    cb_run_hooks pre-snapshot
    cb_snapshot "$TOMCAT_CONF_DIR" "tomcat-pre-cert" \
        /etc/letsencrypt/live \
        /etc/letsencrypt/archive \
        /etc/letsencrypt/renewal \
        /etc/letsencrypt/accounts \
        >/dev/null
    # Backup SSL directory if it exists (for cert rollback)
    [[ -d "$CB_TOMCAT_SSL_DIR" ]] && cb_snapshot "$CB_TOMCAT_SSL_DIR" "tomcat-ssl-pre" >/dev/null
    cb_firewall_snapshot >/dev/null
    cb_run_hooks post-snapshot
}

stage_find_domains() {
    cb_sep
    local _seen=""
    if [[ -n "$CB_DOMAINS" ]]; then
        for d in $CB_DOMAINS; do
            cb_validate_domain "$d" || continue
            [[ " $_seen " == *" $d "* ]] && continue
            VALID_DOMAINS+=("$d")
            _seen="$_seen $d"
        done
    else
        # Extract <Host name="..."> and <Alias> from server.xml via python3 (safe)
        cb_log "Extracting Host name from $TOMCAT_SERVER_XML"
        local domains
        domains=$(python3 -c "
import xml.etree.ElementTree as ET, sys
try:
    root = ET.parse('$TOMCAT_SERVER_XML').getroot()
    seen = set()
    for host in root.iter('Host'):
        n = host.attrib.get('name')
        if n and n != 'localhost' and '.' in n:
            seen.add(n)
        for alias in host.iter('Alias'):
            if alias.text:
                a = alias.text.strip()
                '.' in a and seen.add(a)
    for d in sorted(seen):
        print(d)
except Exception as e:
    sys.exit(0)
" 2>/dev/null)

        # Fallback: FQDN from hostname
        if [[ -z "$domains" ]]; then
            local fqdn; fqdn=$(hostname -f 2>/dev/null)
            [[ "$fqdn" == *.* ]] && domains="$fqdn"
        fi

        for d in $domains; do
            cb_validate_domain "$d" || continue
            if cb_domain_points_here "$d"; then
                VALID_DOMAINS+=("$d")
                cb_ok "Domain OK: $d"
            else
                cb_warn "Domain does not point here: $d"
            fi
        done
    fi

    (( ${#VALID_DOMAINS[@]} > 0 )) || cb_die "No valid domain found"
    cb_hook_context tomcat "${VALID_DOMAINS[@]}"
}

stage_email() {
    if [[ -z "$CB_EMAIL" ]]; then
        CB_EMAIL=$(cb_ask_in "Email" "admin@$(hostname -d 2>/dev/null || echo example.com)")
    fi
    cb_validate_email "$CB_EMAIL" || cb_die "Invalid email: $CB_EMAIL"
}

# ============================================================================
# Port 80 strategy
# ============================================================================
stage_port80_setup() {
    cb_sep
    cb_log "Port 80 strategy: $CB_TOMCAT_PORT80_STRATEGY"
    case "$CB_TOMCAT_PORT80_STRATEGY" in
        iptables)
            if [[ "$CB_CA" == "harica" && "${CB_HARICA_FIREWALL_AUTO_OPEN:-0}" != "1" && "$CB_TOMCAT_PORT80_STRATEGY_CLI" != "1" ]]; then
                cb_warn "CA=harica/EAB: will not set up iptables redirect 80->Tomcat by default."
                cb_warn "Switching port80 strategy to webroot without firewall mutation. For the original behavior use --port80 iptables and CB_HARICA_FIREWALL_AUTO_OPEN=1."
                CB_TOMCAT_PORT80_STRATEGY="webroot"
                stage_port80_setup
                return 0
            fi
            # Redirect 80 -> 8080 (Tomcat default HTTP connector)
            # Tomcat must have it enabled
            local tomcat_http_port
            tomcat_http_port=$(python3 -c "
import xml.etree.ElementTree as ET
root = ET.parse('$TOMCAT_SERVER_XML').getroot()
for c in root.iter('Connector'):
    p = c.attrib.get('protocol', '')
    port = c.attrib.get('port', '')
    if 'HTTP' in p and ('redirectPort' not in c.attrib or port != '443'):
        print(port); break
" 2>/dev/null || echo 8080)
            [[ -z "$tomcat_http_port" ]] && tomcat_http_port=8080
            cb_log "Tomcat HTTP connector port: $tomcat_http_port"
            if cb_firewall_redirect_80_to "$tomcat_http_port"; then
                cb_firewall_ensure_http_https_for_acme
                TOMCAT_ACME_WEBROOT=""
                cb_warn "Certbot --standalone not possible - port 80 is redirected. Using --webroot."
                CB_TOMCAT_PORT80_STRATEGY="webroot"
                stage_port80_setup
            else
                cb_log "Redirect 80->$tomcat_http_port failed, using certbot --standalone"
                TOMCAT_ACME_WEBROOT=""
            fi
            ;;
        webroot)
            if [[ -n "$CB_TOMCAT_ACME_WEBROOT" ]]; then
                TOMCAT_ACME_WEBROOT="$CB_TOMCAT_ACME_WEBROOT"
            else
                local wr=""
                for d in /usr/share/tomcat/webapps/ROOT /var/lib/tomcat/webapps/ROOT; do
                    [[ -d "$(dirname "$d")" ]] && { wr="$d"; break; }
                done
                [[ -z "$wr" ]] && wr="/usr/share/tomcat/webapps/ROOT"
                TOMCAT_ACME_WEBROOT="$wr"
            fi
            mkdir -p "$TOMCAT_ACME_WEBROOT/.well-known/acme-challenge"
            chown -R "$TOMCAT_USER:" "$TOMCAT_ACME_WEBROOT" 2>/dev/null || true
            chmod -R 755 "$TOMCAT_ACME_WEBROOT" 2>/dev/null
            command -v restorecon >/dev/null 2>&1 && restorecon -R "$TOMCAT_ACME_WEBROOT" 2>/dev/null
            cb_ok "ACME webroot: $TOMCAT_ACME_WEBROOT"
            ;;
        proxy)
            cb_log "Port80 strategy 'proxy': assuming reverse proxy (nginx/Apache)"
            cb_warn "In this mode the reverse proxy should handle the cert, not Tomcat."
            TOMCAT_ACME_WEBROOT="${CB_TOMCAT_ACME_WEBROOT:-/var/www/acme}"
            cb_warn "Tomcat-certbot will use --webroot with $TOMCAT_ACME_WEBROOT (must be shared with proxy)"
            mkdir -p "$TOMCAT_ACME_WEBROOT/.well-known/acme-challenge"
            ;;
        *) cb_die "Unknown port80 strategy: $CB_TOMCAT_PORT80_STRATEGY" ;;
    esac
}

# ============================================================================
stage_install_deploy_hook() {
    cb_sep
    local hook="$CB_CERTBOT_HOOK_DIR/certberus-tomcat-reload.sh"
    cb_log "Installing deploy hook: $hook"
    mkdir -p "$CB_TOMCAT_SSL_DIR"
    chown "$TOMCAT_USER:" "$CB_TOMCAT_SSL_DIR" 2>/dev/null || true
    chmod 750 "$CB_TOMCAT_SSL_DIR" 2>/dev/null || true

    if [[ "$CB_DRY_RUN" == "0" ]]; then
        cat > "$hook" <<HOOK_EOF
#!/bin/bash
# Certberus certbot deploy hook for Tomcat - auto-generated.
set -u
LOG="/var/log/certberus/certbot-tomcat.log"
mkdir -p "\$(dirname "\$LOG")" 2>/dev/null || true
[[ -w "\$(dirname "\$LOG")" ]] || LOG="/dev/null"
TS="[\$(date '+%F %T')]"
SSL_DIR="$CB_TOMCAT_SSL_DIR"
SERVICE="$TOMCAT_SERVICE"
TOMCAT_USER="$TOMCAT_USER"

echo "\$TS Renewed: \$RENEWED_DOMAINS (\$RENEWED_LINEAGE)" >> "\$LOG"
command -v logger >/dev/null && logger -t certberus-tomcat "renewal: \$RENEWED_DOMAINS"

# Copy for each renewed domain
errors=0
for domain in \$RENEWED_DOMAINS; do
    mkdir -p "\$SSL_DIR/\$domain" || { ((errors++)); continue; }
    # Preserve previous copies for rollback
    [[ -f "\$SSL_DIR/\$domain/fullchain.pem" ]] && \\
        cp "\$SSL_DIR/\$domain/fullchain.pem" "\$SSL_DIR/\$domain/fullchain.prev.pem" 2>/dev/null
    [[ -f "\$SSL_DIR/\$domain/privkey.pem" ]] && \\
        cp "\$SSL_DIR/\$domain/privkey.pem" "\$SSL_DIR/\$domain/privkey.prev.pem" 2>/dev/null

    if cp "\$RENEWED_LINEAGE/fullchain.pem" "\$SSL_DIR/\$domain/" && \\
       cp "\$RENEWED_LINEAGE/privkey.pem" "\$SSL_DIR/\$domain/"; then
        chown -R "\$TOMCAT_USER:" "\$SSL_DIR/\$domain" 2>/dev/null
        chmod 640 "\$SSL_DIR/\$domain/"*.pem 2>/dev/null
        echo "\$TS Copied: \$domain" >> "\$LOG"
    else
        echo "\$TS ERROR copy \$domain" >> "\$LOG"
        ((errors++))
    fi
done

# Export for certberus hooks
export CA_EVENT="renewed"
export CA_WEBSERVER="tomcat"
export CA_PRIMARY_DOMAIN=\$(echo "\$RENEWED_DOMAINS" | awk '{print \$1}')
export CA_DOMAIN_LIST="\$RENEWED_DOMAINS"
export CA_CERT_PATH="\$RENEWED_LINEAGE/fullchain.pem"
export CA_KEY_PATH="\$RENEWED_LINEAGE/privkey.pem"
export CA_SOURCE="certbot"

HOOK_TO="\${CB_HOOK_TIMEOUT:-60}"
HAVE_TO=0; command -v timeout >/dev/null 2>&1 && HAVE_TO=1
for ev in renewed post-deploy; do
    D="/etc/certberus/hooks/\${ev}.d"
    [[ -d "\$D" ]] || continue
    for f in "\$D"/*; do
        [[ -x "\$f" ]] || continue
        case "\$f" in *.example|*.bak|*.disabled) continue ;; esac
        if (( HAVE_TO )); then
            timeout "\$HOOK_TO" "\$f" >> "\$LOG" 2>&1 || true
        else
            "\$f" >> "\$LOG" 2>&1 || true
        fi
    done
done

# Atomic restart with rollback
if systemctl restart "\$SERVICE"; then
    sleep 3
    if systemctl is-active --quiet "\$SERVICE"; then
        echo "\$TS Tomcat restart OK" >> "\$LOG"
        exit 0
    fi
fi

echo "\$TS ERROR: Tomcat restart failed - ROLLBACK to previous cert" >> "\$LOG"
command -v logger >/dev/null && logger -t certberus-tomcat -p daemon.err "Restart failed - rolling back"
for domain in \$RENEWED_DOMAINS; do
    [[ -f "\$SSL_DIR/\$domain/fullchain.prev.pem" ]] && \\
        mv "\$SSL_DIR/\$domain/fullchain.prev.pem" "\$SSL_DIR/\$domain/fullchain.pem"
    [[ -f "\$SSL_DIR/\$domain/privkey.prev.pem" ]] && \\
        mv "\$SSL_DIR/\$domain/privkey.prev.pem" "\$SSL_DIR/\$domain/privkey.pem"
done
systemctl restart "\$SERVICE" 2>/dev/null || true
echo "\$TS Rollback completed" >> "\$LOG"
exit 1
HOOK_EOF
        chmod +x "$hook"
    fi
    cb_ok "Deploy hook: $hook"
}

stage_issue_cert() {
    cb_sep
    cb_run_hooks pre-issue

    local acme_url="$CB_ACME_URL"
    if [[ -z "$acme_url" ]]; then
        case "$CB_CA" in
            letsencrypt)
                [[ "$CB_STAGING" == "1" ]] && acme_url="https://acme-staging-v02.api.letsencrypt.org/directory"
                ;;
            harica)
                acme_url="${CB_ACME_URL_HARICA:-}"
                CB_EAB_REQUIRED=1
                [[ -n "$acme_url" ]] || cb_die "CA harica requires per-account --acme-url/CB_ACME_URL_HARICA and EAB KID/HMAC (e.g. https://acme.harica.gr/<alias>/directory)."
                [[ "$acme_url" != *".../"* && "$acme_url" != *"VAS_"* && "$acme_url" != *"<"* ]] || cb_die "HARICA ACME URL looks like a placeholder: $acme_url"
                ;;
            zerossl) acme_url="${CB_ACME_URL_ZEROSSL:-https://acme.zerossl.com/v2/DV90}"; CB_EAB_REQUIRED=1 ;;
        esac
    fi

    if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
        [[ -n "$CB_EAB_KID" ]] || CB_EAB_KID=$(cb_ask_in "EAB KID" "")
        [[ -n "$CB_EAB_HMAC" ]] || CB_EAB_HMAC=$(cb_ask_secret "EAB HMAC")
        [[ -n "$CB_EAB_KID" && -n "$CB_EAB_HMAC" ]] || cb_die "CA $CB_CA requires EAB"
    fi

    # Issue each domain separately (Tomcat SNI is cleaner this way)
    local d
    for d in "${VALID_DOMAINS[@]}"; do
        cb_log "Issuing cert for: $d"
        local args=(certonly)
        if [[ -n "$TOMCAT_ACME_WEBROOT" ]]; then
            args+=(--webroot -w "$TOMCAT_ACME_WEBROOT")
        else
            args+=(--standalone)
        fi
        args+=(--email "$CB_EMAIL" --agree-tos --no-eff-email \
               --non-interactive --keep-until-expiring \
               --cert-name "$d" -d "$d")
        [[ -n "$acme_url" ]] && args+=(--server "$acme_url")
        [[ "$CB_EAB_REQUIRED" == "1" ]] && args+=(--eab-kid "$CB_EAB_KID" --eab-hmac-key "$CB_EAB_HMAC")
        [[ "$CB_DRY_RUN" == "1" ]] && args+=(--dry-run)

        cb_retry "${CB_RETRY_COUNT:-3}" "${CB_RETRY_DELAY:-10}" cb_certbot_issue "$d" "${args[@]}" || cb_die "certbot failed for $d"

        # Copy to SSL dir for Tomcat
        if [[ "$CB_DRY_RUN" == "0" ]]; then
            mkdir -p "$CB_TOMCAT_SSL_DIR/$d"
            cp "/etc/letsencrypt/live/$d/fullchain.pem" "$CB_TOMCAT_SSL_DIR/$d/" || cb_die "Cannot copy fullchain.pem for $d to $CB_TOMCAT_SSL_DIR"
            cp "/etc/letsencrypt/live/$d/privkey.pem" "$CB_TOMCAT_SSL_DIR/$d/" || cb_die "Cannot copy privkey.pem for $d to $CB_TOMCAT_SSL_DIR"
            [[ -s "$CB_TOMCAT_SSL_DIR/$d/fullchain.pem" && -s "$CB_TOMCAT_SSL_DIR/$d/privkey.pem" ]] || cb_die "Certificate copy for $d is empty/incomplete"
            chown -R "$TOMCAT_USER:" "$CB_TOMCAT_SSL_DIR/$d" 2>/dev/null || true
            chmod 640 "$CB_TOMCAT_SSL_DIR/$d/"*.pem 2>/dev/null || true
        fi
    done
    cb_ok "All certs issued"

    # Clean up temporary ACME ROOT context
    _cb_tomcat_restore_root_context

    local primary="${VALID_DOMAINS[0]}"
    cb_hook_set_cert "$CB_TOMCAT_SSL_DIR/$primary/fullchain.pem" \
                    "$CB_TOMCAT_SSL_DIR/$primary/privkey.pem" \
                    "$CB_CA" "certbot"
    export CA_SOURCE="certbot"
    cb_run_hooks post-issue
}

stage_inject_server_xml() {
    cb_sep
    cb_log "Configuring HTTPS connector in server.xml"
    cb_run_hooks pre-deploy

    local primary="${VALID_DOMAINS[0]}"
    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] Skipping server.xml changes"
        return 0
    fi

    # Python3 XML manipulation - find existing Connector on 443 or create a new one.
    python3 <<PYEOF
import xml.etree.ElementTree as ET
import sys, shutil, os
from datetime import datetime

XML = "$TOMCAT_SERVER_XML"
SSL_DIR = "$CB_TOMCAT_SSL_DIR"
DOMAINS = """${VALID_DOMAINS[@]}""".split()
PRIMARY = DOMAINS[0]

# Backup
shutil.copy(XML, XML + ".bak_" + datetime.now().strftime("%Y%m%d_%H%M%S"))

tree = ET.parse(XML)
root = tree.getroot()

# Find Service (first one)
svc = root.find('Service')
if svc is None:
    print("ERROR: Service element not found", file=sys.stderr); sys.exit(1)

# Existing :443 connector?
https_conn = None
for c in svc.findall('Connector'):
    if c.attrib.get('port') == '443':
        https_conn = c; break

if https_conn is None:
    https_conn = ET.SubElement(svc, 'Connector')
    https_conn.set('port', '443')
    https_conn.set('protocol', 'org.apache.coyote.http11.Http11NioProtocol')
    https_conn.set('maxThreads', '150')
    https_conn.set('SSLEnabled', 'true')
    https_conn.set('scheme', 'https')
    https_conn.set('secure', 'true')
    # add newline text between positions for readability
    https_conn.tail = "\n    "
else:
    https_conn.set('SSLEnabled', 'true')
    https_conn.set('scheme', 'https')
    https_conn.set('secure', 'true')

# Remove existing SSLHostConfig (cleaner than merge)
for h in list(https_conn.findall('SSLHostConfig')):
    https_conn.remove(h)

# Default SSLHostConfig (primary)
def add_host_config(parent, host_name, is_default=False):
    hc = ET.SubElement(parent, 'SSLHostConfig')
    if not is_default:
        hc.set('hostName', host_name)
    hc.set('protocols', 'TLSv1.2+TLSv1.3')
    hc.set('certificateVerification', 'none')
    hc.text = "\n        "
    hc.tail = "\n    "
    cert = ET.SubElement(hc, 'Certificate')
    cert.set('certificateFile', f"{SSL_DIR}/{host_name}/fullchain.pem")
    cert.set('certificateKeyFile', f"{SSL_DIR}/{host_name}/privkey.pem")
    cert.tail = "\n    "

add_host_config(https_conn, PRIMARY, is_default=True)
for d in DOMAINS[1:]:
    add_host_config(https_conn, d)

tree.write(XML, encoding='UTF-8', xml_declaration=True)
print("Connector :443 configured for {} domain(s)".format(len(DOMAINS)))
PYEOF

    cb_ok "server.xml updated"
    cb_run_hooks post-deploy
}

stage_enable_timer() {
    if systemctl list-unit-files 2>/dev/null | grep '^certbot\.timer'; then >/dev/null
        systemctl enable --now certbot.timer >/dev/null 2>&1 && cb_ok "certbot.timer enabled"
    fi
}

stage_restart_test() {
    cb_sep
    cb_run_hooks pre-reload
    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] skipping restart"
        return 0
    fi
    cb_log "Restart $TOMCAT_SERVICE"
    if ! cb_svc_restart "$TOMCAT_SERVICE"; then
        cb_error "Tomcat restart failed - check journalctl -u $TOMCAT_SERVICE"
        cb_rollback_hint
        cb_die "Restart FAIL"
    fi
    sleep 5
    if cb_svc_is_active "$TOMCAT_SERVICE"; then
        cb_ok "Tomcat is running"
    else
        cb_error "Tomcat is not running after restart"
        cb_die "Tomcat down - ROLLBACK: $(cb_rollback_hint)"
    fi

    # TCP test port 443
    if timeout 5 bash -c "echo >/dev/tcp/127.0.0.1/443" 2>/dev/null; then
        cb_ok "Port 443 responds"
    else
        cb_warn "Port 443 not responding - possible problem in server.xml"
    fi
    cb_mark_installed "tomcat-certbot"
    cb_run_hooks post-reload
}

# ============================================================================
on_failure() {
    local rc=$1
    [[ $rc -eq 0 ]] && return 0
    cb_error "Script failed (rc=$rc, stage=${CURRENT_STAGE:-?})"
    cb_rollback_hint
    export CA_PREV_EXIT="$rc" CA_PREV_STAGE="${CURRENT_STAGE:-?}"
    cb_run_hooks on-failure 2>/dev/null || true
}
cb_on_exit_register on_failure
cb_setup_traps

run_stage() { CURRENT_STAGE="$1"; cb_debug "== stage: $1 =="; "stage_$1"; }

main() {
    parse_args "$@"
    run_stage prepare
    run_stage detect_tomcat
    cb_preflight_tomcat || cb_die "Tomcat preflight failed - fix server.xml first"
    run_stage install_packages
    run_stage snapshot
    run_stage find_domains
    run_stage email
    run_stage port80_setup
    run_stage install_deploy_hook
    run_stage issue_cert
    run_stage inject_server_xml
    run_stage enable_timer
    run_stage restart_test
    cb_sep
    cb_ok "Tomcat HTTPS ready. Domains: ${VALID_DOMAINS[*]}"
    cb_log "Test: curl -vI https://${VALID_DOMAINS[0]}/"
}
main "$@"
