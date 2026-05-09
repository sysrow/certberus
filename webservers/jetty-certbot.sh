#!/bin/bash
# certberus/webservers/jetty-certbot.sh
# Jetty (including Shibboleth IdP) + certbot + Let's Encrypt / HARICA / ZeroSSL
#
# Strategy:
#   1. Detect Jetty instance (systemd unit, JETTY_HOME/BASE, keystore)
#   2. certbot certonly (standalone/webroot)
#   3. PEM -> PKCS12 keystore conversion
#   4. Deploy hook for automatic conversion on renewal
#   5. Jetty restart
#
# Supports:
#   - Standalone Jetty (jetty.service)
#   - Shibboleth IdP on Jetty (shibboleth-idp.service, jetty9.service)
#   - Keystore path detection from start.ini / start.d/ssl.ini
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
cb_load_config

: "${CB_JETTY_KEYSTORE_PASSWORD:=changeit}"
: "${CB_JETTY_KEYSTORE_PATH:=}"
: "${CB_JETTY_SSL_PORT:=8443}"
: "${CB_CERTBOT_HOOK_DIR:=/etc/letsencrypt/renewal-hooks/deploy}"

CB_CA="${CB_CA:-letsencrypt}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_EMAIL="${CB_EMAIL:-}"
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"
VALID_DOMAINS=()

_JETTY_SVC=""
_JETTY_HOME=""
_JETTY_BASE=""
_JETTY_USER=""
_JETTY_IS_SHIBBOLETH=0

usage() {
    cat <<USAGE
jetty-certbot.sh - Jetty + certbot + PKCS12 keystore

Usage: $0 [OPTIONS]

  -t, --staging        Staging CA
  -y, --yes            Non-interactive
  -n, --dry-run        Simulation
  -v, --verbose        Debug
      --domain D       Domain (repeatable)
      --email E        Contact email
      --ca NAME        letsencrypt | harica | zerossl
      --acme-url URL   Custom ACME URL
      --webroot DIR    ACME webroot (default: standalone)
      --eab-kid KID
      --eab-hmac HMAC
      --no-firewall    Never automatically modify firewall
      --open-firewall  Explicitly allow firewall mutations
      --set CB_X=Y     Advanced override
  -h, --help
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
            --webroot) [[ $# -ge 2 ]] || cb_die "--webroot requires a value"; shift; _JETTY_WEBROOT="$1" ;;
            --eab-kid) shift; CB_EAB_KID="$1" ;;
            --eab-hmac) shift; CB_EAB_HMAC="$1" ;;
            --no-firewall) cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=0" ;;
            --open-firewall)
                cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=1"
                cb_apply_cli_set "CB_HARICA_FIREWALL_AUTO_OPEN=1"
                ;;
            --set) [[ $# -ge 2 ]] || cb_die "--set requires a value CB_NAME=value"; shift; cb_apply_cli_set "$1" ;;
            *) cb_warn "Unknown arg: $1" ;;
        esac
        shift
    done
}

# ============================================================================
stage_prepare() {
    cb_banner "Certberus / Jetty / certbot + PKCS12"
    cb_require_root
    cb_hook_context jetty ""
    mkdir -p "$CB_LOG_DIR" "$CB_STATE_DIR" "$CB_CERTBOT_HOOK_DIR" 2>/dev/null
    cb_run_hooks pre-install
}

stage_detect_jetty() {
    cb_sep
    cb_log "Looking for Jetty instance..."

    # Looking for systemd service
    local svc=""
    for s in jetty jetty9 jetty10 jetty11 jetty12 shibboleth-idp; do
        if systemctl list-unit-files 2>/dev/null | grep -E "^${s}\.service" >/dev/null; then
            svc="$s"
            break
        fi
    done
    [[ -z "$svc" ]] && cb_die "Jetty systemd service not found (searched for jetty, jetty9-12, shibboleth-idp)"
    _JETTY_SVC="$svc"
    cb_ok "Service: $_JETTY_SVC"

    [[ "$_JETTY_SVC" == "shibboleth-idp" || "$_JETTY_SVC" == *shibboleth* ]] && _JETTY_IS_SHIBBOLETH=1

    # JETTY_HOME / JETTY_BASE from service environment or standard paths
    local env_file=""
    env_file=$(systemctl show "$_JETTY_SVC" -p EnvironmentFile 2>/dev/null | sed 's/^EnvironmentFile=//' | tr -d '"')
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file" 2>/dev/null || true
    fi

    if [[ -z "${JETTY_HOME:-}" ]]; then
        for p in /opt/jetty /usr/share/jetty /usr/share/jetty9 /opt/shibboleth-idp/jetty-base/.. /usr/local/jetty; do
            [[ -d "$p" && -f "$p/start.jar" ]] && { JETTY_HOME="$p"; break; }
        done
    fi
    _JETTY_HOME="${JETTY_HOME:-}"

    if [[ -z "${JETTY_BASE:-}" ]]; then
        for p in /opt/jetty/base /var/lib/jetty /opt/shibboleth-idp/jetty-base /etc/jetty; do
            [[ -d "$p" ]] && { JETTY_BASE="$p"; break; }
        done
        [[ -z "${JETTY_BASE:-}" && -n "$_JETTY_HOME" ]] && JETTY_BASE="$_JETTY_HOME"
    fi
    _JETTY_BASE="${JETTY_BASE:-}"

    [[ -n "$_JETTY_HOME" ]] && cb_log "JETTY_HOME: $_JETTY_HOME"
    [[ -n "$_JETTY_BASE" ]] && cb_log "JETTY_BASE: $_JETTY_BASE"

    # Determine the user under which Jetty runs
    _JETTY_USER=$(systemctl show "$_JETTY_SVC" -p User 2>/dev/null | sed 's/^User=//')
    [[ -z "$_JETTY_USER" || "$_JETTY_USER" == "[not set]" ]] && _JETTY_USER="jetty"
    id "$_JETTY_USER" >/dev/null 2>&1 || _JETTY_USER="root"
    cb_log "Jetty user: $_JETTY_USER"

    # Detect keystore path
    if [[ -z "$CB_JETTY_KEYSTORE_PATH" && -n "$_JETTY_BASE" ]]; then
        local ks_path=""
        # Search in start.ini and start.d/ssl.ini
        for ini in "$_JETTY_BASE/start.ini" "$_JETTY_BASE/start.d/ssl.ini" "$_JETTY_BASE/start.d/https.ini"; do
            [[ -f "$ini" ]] || continue
            ks_path=$(grep -E '^\s*jetty\.sslContext\.keyStorePath\s*=' "$ini" 2>/dev/null | head -1 | sed 's/^.*=\s*//')
            [[ -n "$ks_path" ]] && break
        done
        # Shibboleth IdP credentials
        if [[ -z "$ks_path" && "$_JETTY_IS_SHIBBOLETH" == "1" ]]; then
            for p in /opt/shibboleth-idp/credentials/idp-userfacing.p12 /opt/shibboleth-idp/credentials/idp-browser.p12; do
                [[ -f "$p" ]] && { ks_path="$p"; break; }
            done
        fi
        if [[ -n "$ks_path" ]]; then
            CB_JETTY_KEYSTORE_PATH="$ks_path"
        else
            CB_JETTY_KEYSTORE_PATH="${_JETTY_BASE}/etc/keystore.p12"
        fi
    fi
    [[ -z "$CB_JETTY_KEYSTORE_PATH" ]] && CB_JETTY_KEYSTORE_PATH="/etc/jetty/keystore.p12"
    cb_log "Keystore: $CB_JETTY_KEYSTORE_PATH"

    (( _JETTY_IS_SHIBBOLETH )) && cb_log "Detected: Shibboleth IdP"
}

stage_install_packages() {
    cb_sep
    local need=()
    cb_pkg_installed certbot || need+=(certbot)
    command -v openssl >/dev/null 2>&1 || need+=(openssl)
    if (( ${#need[@]} > 0 )); then
        cb_log "Missing: ${need[*]}"
        cb_ask_yn "Install?" "Y/n" || cb_die "Aborting"
        cb_pkg_install "${need[@]}" || cb_die "Installation failed"
    else
        cb_ok "Packages are present (certbot, openssl)"
    fi
    cb_run_hooks post-install
}

stage_snapshot() {
    cb_sep
    cb_run_hooks pre-snapshot
    local ks_dir
    ks_dir=$(dirname "$CB_JETTY_KEYSTORE_PATH")
    cb_snapshot "$ks_dir" "jetty-pre-cert" \
        /etc/letsencrypt/live \
        /etc/letsencrypt/archive \
        /etc/letsencrypt/renewal \
        /etc/letsencrypt/accounts \
        >/dev/null
    cb_run_hooks post-snapshot
}

stage_find_domains() {
    cb_sep
    local _seen=""
    if [[ -n "$CB_DOMAINS" ]]; then
        for d in $CB_DOMAINS; do
            cb_validate_domain "$d" || { cb_warn "Ignoring: $d"; continue; }
            [[ " $_seen " == *" $d "* ]] && continue
            VALID_DOMAINS+=("$d")
            _seen="$_seen $d"
        done
    else
        cb_log "Looking for domains in Jetty configuration..."
        local domains=""

        # Shibboleth IdP: idp.properties
        if [[ "$_JETTY_IS_SHIBBOLETH" == "1" ]]; then
            local idp_props=""
            for p in /opt/shibboleth-idp/conf/idp.properties /etc/shibboleth-idp/conf/idp.properties; do
                [[ -f "$p" ]] && { idp_props="$p"; break; }
            done
            if [[ -n "$idp_props" ]]; then
                local entity_id
                entity_id=$(grep -E '^\s*idp\.entityID\s*=' "$idp_props" 2>/dev/null | head -1 | sed 's/^.*=\s*//' | sed 's|^https\?://||' | sed 's|/.*||')
                [[ -n "$entity_id" ]] && domains="$entity_id"
            fi
        fi

        # Jetty XML virtualHosts
        if [[ -z "$domains" && -n "$_JETTY_BASE" ]]; then
            domains=$(grep -rhE '<Set name="virtualHosts">' "$_JETTY_BASE" 2>/dev/null \
                | grep -oE '[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}' | sort -u | tr '\n' ' ')
        fi

        # Hostname fallback
        if [[ -z "$domains" ]]; then
            local fqdn
            fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null)
            if [[ -n "$fqdn" && "$fqdn" == *.* ]]; then
                cb_warn "No domains found in configuration, trying hostname: $fqdn"
                domains="$fqdn"
            fi
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
    (( ${#VALID_DOMAINS[@]} > 0 )) || cb_die "No valid domain"
    cb_hook_context jetty "${VALID_DOMAINS[@]}"
}

stage_email() {
    if [[ -z "$CB_EMAIL" ]]; then
        CB_EMAIL=$(cb_ask_in "Contact email" "admin@$(hostname -d 2>/dev/null || echo example.com)")
    fi
    cb_validate_email "$CB_EMAIL" || cb_die "Invalid email: $CB_EMAIL"
}

stage_install_deploy_hook() {
    cb_sep
    local hook="$CB_CERTBOT_HOOK_DIR/certberus-jetty-p12.sh"
    cb_log "Installing deploy hook: $hook"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        mkdir -p "$CB_CERTBOT_HOOK_DIR"
        cat > "$hook" <<HOOK_EOF
#!/bin/bash
# Certberus certbot deploy hook for Jetty - generated, do not edit.
# PEM -> PKCS12 conversion on every renewal.
set -u
LOG="/var/log/certberus/certbot-renewal.log"
mkdir -p "\$(dirname "\$LOG")" 2>/dev/null || true
[[ -w "\$(dirname "\$LOG")" ]] || LOG="/dev/null"
TS="[\$(date '+%F %T')]"
echo "\$TS Renewed: \$RENEWED_DOMAINS (\$RENEWED_LINEAGE)" >> "\$LOG" 2>/dev/null
command -v logger >/dev/null && logger -t certberus-jetty "renewal: \$RENEWED_DOMAINS"

KS_PATH="${CB_JETTY_KEYSTORE_PATH}"
KS_PASS="${CB_JETTY_KEYSTORE_PASSWORD}"
KS_DIR="\$(dirname "\$KS_PATH")"
JETTY_USER="${_JETTY_USER}"
JETTY_SVC="${_JETTY_SVC}"

# Backup existing keystore
[[ -f "\$KS_PATH" ]] && cp -p "\$KS_PATH" "\$KS_PATH.bak" 2>/dev/null

# PEM -> PKCS12
mkdir -p "\$KS_DIR" 2>/dev/null
if openssl pkcs12 -export \
    -in "\$RENEWED_LINEAGE/fullchain.pem" \
    -inkey "\$RENEWED_LINEAGE/privkey.pem" \
    -out "\$KS_PATH.new" \
    -name jetty \
    -passout "pass:\$KS_PASS" 2>>"\$LOG"; then
    mv -f "\$KS_PATH.new" "\$KS_PATH"
    chown "\$JETTY_USER:" "\$KS_PATH" 2>/dev/null
    chmod 640 "\$KS_PATH"
    echo "\$TS PKCS12 keystore updated: \$KS_PATH" >> "\$LOG"
else
    echo "\$TS ERROR: PKCS12 conversion failed" >> "\$LOG"
    [[ -f "\$KS_PATH.bak" ]] && mv -f "\$KS_PATH.bak" "\$KS_PATH"
    exit 1
fi

# Restart Jetty
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "\$JETTY_SVC" 2>/dev/null; then
    if systemctl restart "\$JETTY_SVC" >>/dev/null 2>&1; then
        echo "\$TS \$JETTY_SVC restart OK" >> "\$LOG"
    else
        echo "\$TS ERROR: \$JETTY_SVC restart failed" >> "\$LOG"
        [[ -f "\$KS_PATH.bak" ]] && mv -f "\$KS_PATH.bak" "\$KS_PATH" && systemctl restart "\$JETTY_SVC" 2>/dev/null
        exit 1
    fi
fi

# Certberus hooks
export CA_EVENT="renewed"
export CA_WEBSERVER="jetty"
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
HOOK_EOF
        chmod +x "$hook"
    fi
    cb_ok "Deploy hook: $hook"
}

stage_firewall() {
    cb_firewall_ensure_http_https_for_acme
}

stage_issue_cert() {
    cb_sep
    cb_run_hooks pre-issue

    local acme_url="$CB_ACME_URL"
    case "$CB_CA" in
        letsencrypt)
            [[ -z "$acme_url" && "$CB_STAGING" == "1" ]] && acme_url="https://acme-staging-v02.api.letsencrypt.org/directory"
            ;;
        harica)
            [[ -z "$acme_url" ]] && acme_url="${CB_ACME_URL_HARICA:-}"
            CB_EAB_REQUIRED=1
            [[ -n "$acme_url" ]] || cb_die "CA harica requires --acme-url"
            [[ "$acme_url" != *".../"* && "$acme_url" != *"VAS_"* && "$acme_url" != *"<"* ]] || cb_die "HARICA ACME URL looks like a placeholder: $acme_url"
            ;;
        zerossl)
            [[ -z "$acme_url" ]] && acme_url="${CB_ACME_URL_ZEROSSL:-https://acme.zerossl.com/v2/DV90}"
            CB_EAB_REQUIRED=1
            ;;
    esac

    if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
        [[ -n "$CB_EAB_KID" ]] || CB_EAB_KID=$(cb_ask_in "EAB KID" "")
        [[ -n "$CB_EAB_HMAC" ]] || CB_EAB_HMAC=$(cb_ask_secret "EAB HMAC")
        [[ -n "$CB_EAB_KID" && -n "$CB_EAB_HMAC" ]] || cb_die "CA $CB_CA requires EAB"
    fi

    local -a args=(certonly --non-interactive --agree-tos --no-eff-email --keep-until-expiring)
    args+=(--email "$CB_EMAIL")
    [[ -n "$acme_url" ]] && args+=(--server "$acme_url")
    [[ "$CB_EAB_REQUIRED" == "1" ]] && args+=(--eab-kid "$CB_EAB_KID" --eab-hmac-key "$CB_EAB_HMAC")
    [[ "$CB_DRY_RUN" == "1" ]] && args+=(--dry-run)

    if [[ -n "${_JETTY_WEBROOT:-}" ]]; then
        args+=(--webroot -w "$_JETTY_WEBROOT")
    else
        args+=(--standalone)
    fi

    local primary="${VALID_DOMAINS[0]}"
    args+=(--cert-name "$primary")
    for d in "${VALID_DOMAINS[@]}"; do
        args+=(-d "$d")
    done

    # Detect staging->production transition
    local live_cert="/etc/letsencrypt/live/$primary/fullchain.pem"
    if [[ -f "$live_cert" ]]; then
        local cur_issuer
        cur_issuer=$(openssl x509 -in "$live_cert" -noout -issuer 2>/dev/null || true)
        if [[ "$CB_STAGING" != "1" ]] && printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
            cb_warn "Existing cert is staging. Forcing --force-renewal."
            args+=(--force-renewal)
        fi
        if [[ "$CB_STAGING" == "1" ]] && ! printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
            args+=(--force-renewal --break-my-certs)
        fi
    fi

    cb_log "certbot ${args[*]}"
    if ! cb_retry "${CB_RETRY_COUNT:-3}" "${CB_RETRY_DELAY:-10}" cb_certbot_issue "$primary" "${args[@]}"; then
        cb_die "certbot failed for: ${VALID_DOMAINS[*]}"
    fi
    cb_ok "Certificate issued: ${VALID_DOMAINS[*]}"
    cb_hook_set_cert "/etc/letsencrypt/live/$primary/fullchain.pem" \
                    "/etc/letsencrypt/live/$primary/privkey.pem" \
                    "$CB_CA" "certbot"
    cb_run_hooks post-issue
}

stage_convert_keystore() {
    cb_sep
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping PKCS12 conversion"; return 0; }

    local primary="${VALID_DOMAINS[0]}"
    local cert="/etc/letsencrypt/live/$primary/fullchain.pem"
    local key="/etc/letsencrypt/live/$primary/privkey.pem"

    [[ -f "$cert" && -f "$key" ]] || { cb_warn "Cert/key does not exist, skipping keystore conversion"; return 0; }

    local ks_dir
    ks_dir=$(dirname "$CB_JETTY_KEYSTORE_PATH")
    mkdir -p "$ks_dir" 2>/dev/null

    [[ -f "$CB_JETTY_KEYSTORE_PATH" ]] && cp -p "$CB_JETTY_KEYSTORE_PATH" "$CB_JETTY_KEYSTORE_PATH.bak"

    cb_log "Converting PEM -> PKCS12: $CB_JETTY_KEYSTORE_PATH"
    if openssl pkcs12 -export \
        -in "$cert" \
        -inkey "$key" \
        -out "$CB_JETTY_KEYSTORE_PATH.new" \
        -name jetty \
        -passout "pass:$CB_JETTY_KEYSTORE_PASSWORD" 2>>"$CB_LOG_FILE"; then
        mv -f "$CB_JETTY_KEYSTORE_PATH.new" "$CB_JETTY_KEYSTORE_PATH"
        chown "$_JETTY_USER:" "$CB_JETTY_KEYSTORE_PATH" 2>/dev/null
        chmod 640 "$CB_JETTY_KEYSTORE_PATH"
        cb_ok "PKCS12 keystore created"
    else
        cb_die "PKCS12 conversion failed"
    fi
}

stage_inject_jetty_ssl() {
    cb_sep
    [[ -z "$_JETTY_BASE" ]] && { cb_log "JETTY_BASE is unknown, skipping SSL configuration"; return 0; }
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping Jetty SSL configuration"; return 0; }

    # Check whether the SSL module is already active
    local ssl_active=0
    for ini in "$_JETTY_BASE/start.ini" "$_JETTY_BASE/start.d/ssl.ini"; do
        [[ -f "$ini" ]] || continue
        if grep -E '^\s*--module=ssl' "$ini" 2>/dev/null; then >/dev/null
            ssl_active=1
            break
        fi
    done

    if (( ssl_active )); then
        cb_ok "Jetty SSL module is active"
    else
        cb_log "Jetty SSL module is not active"
        if [[ -n "$_JETTY_HOME" && -f "$_JETTY_HOME/start.jar" ]]; then
            cb_log "Activating SSL module via start.jar..."
            (cd "$_JETTY_BASE" && java -jar "$_JETTY_HOME/start.jar" --add-module=ssl 2>>"$CB_LOG_FILE") || true
        fi
    fi

    local target_ini="$_JETTY_BASE/start.d/ssl.ini"
    [[ -f "$target_ini" ]] || target_ini="$_JETTY_BASE/start.ini"
    [[ -f "$target_ini" ]] || { cb_warn "No Jetty ini file for SSL configuration"; return 0; }

    local need_append=0
    for prop in keyStorePath keyStorePassword keyStoreType; do
        if ! grep -E "^\s*jetty\.sslContext\.${prop}\s*=" "$target_ini" >/dev/null 2>&1; then
            need_append=1
            break
        fi
    done

    if (( need_append )); then
        sed -i '/^\s*#.*jetty\.sslContext\.keyStore/d' "$target_ini"
        cb_log "Appending keystore configuration to $target_ini"
        cat >> "$target_ini" <<SSL_INI
jetty.sslContext.keyStorePath=$CB_JETTY_KEYSTORE_PATH
jetty.sslContext.keyStorePassword=$CB_JETTY_KEYSTORE_PASSWORD
jetty.sslContext.keyStoreType=PKCS12
SSL_INI
    else
        local cur_ks
        cur_ks=$(grep -E '^\s*jetty\.sslContext\.keyStorePath\s*=' "$target_ini" | head -1 | sed 's/^.*=\s*//')
        if [[ "$cur_ks" != "$CB_JETTY_KEYSTORE_PATH" ]]; then
            cb_log "Updating keyStorePath: $cur_ks -> $CB_JETTY_KEYSTORE_PATH"
            sed -i "s|^\(\s*jetty\.sslContext\.keyStorePath\s*=\).*|\1$CB_JETTY_KEYSTORE_PATH|" "$target_ini"
        fi
    fi
}

stage_enable_timer() {
    if systemctl list-unit-files 2>/dev/null | grep '^certbot\.timer'; then >/dev/null
        systemctl enable --now certbot.timer >/dev/null 2>&1 && cb_ok "certbot.timer activated"
    elif systemctl list-unit-files 2>/dev/null | grep '^snap.certbot.renew.timer'; then >/dev/null
        systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 && cb_ok "snap certbot.renew.timer enabled"
    fi
}

stage_restart_test() {
    cb_sep
    cb_run_hooks pre-reload
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping Jetty restart"; return 0; }

    cb_log "Restarting $_JETTY_SVC..."
    if cb_svc_restart "$_JETTY_SVC"; then
        sleep 3
        if cb_svc_is_active "$_JETTY_SVC"; then
            cb_ok "$_JETTY_SVC is running"
        else
            cb_error "$_JETTY_SVC is not running after restart"
            if [[ -f "$CB_JETTY_KEYSTORE_PATH.bak" ]]; then
                cb_warn "Rolling back keystore..."
                mv -f "$CB_JETTY_KEYSTORE_PATH.bak" "$CB_JETTY_KEYSTORE_PATH"
                cb_svc_restart "$_JETTY_SVC" 2>/dev/null || true
            fi
            cb_die "$_JETTY_SVC restart failed"
        fi
    else
        cb_die "$_JETTY_SVC restart failed"
    fi
    cb_mark_installed "jetty-certbot"
    cb_run_hooks post-reload
}

# ============================================================================
on_failure() {
    local rc=$1
    [[ $rc -eq 0 ]] && return 0
    cb_error "Script failed (rc=$rc)"
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
    run_stage detect_jetty
    run_stage install_packages
    run_stage snapshot
    run_stage find_domains
    run_stage email
    run_stage firewall
    run_stage install_deploy_hook
    run_stage issue_cert
    run_stage convert_keystore
    run_stage inject_jetty_ssl
    run_stage enable_timer
    run_stage restart_test
    cb_sep
    cb_ok "Done. Domains: ${VALID_DOMAINS[*]}"
    cb_log "Keystore: $CB_JETTY_KEYSTORE_PATH"
    cb_log "Log: $CB_LOG_FILE"
    [[ "$CB_STAGING" == "1" ]] && cb_warn "STAGING mode - cert is not trusted in browsers"
}
main "$@"
