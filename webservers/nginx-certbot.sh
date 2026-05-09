#!/bin/bash
# certberus/webservers/nginx-certbot.sh
# nginx + certbot (webroot) - Let's Encrypt or CESNET/HARICA via EAB.
#
# Strategy: certbot issues the cert, nginx reloads. Cert resides
# in /etc/letsencrypt/live/DOMAIN/ and is used directly (symlinks).
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

: "${CB_NGINX_CONF_DIR:=/etc/nginx}"
: "${CB_NGINX_WEBROOT:=}"
: "${CB_CERTBOT_HOOK_DIR:=/etc/letsencrypt/renewal-hooks/deploy}"

# OS-dispatch: Debian uses sites-available/sites-enabled, RHEL uses conf.d
case "$CB_OS_ID" in
    debian|ubuntu)
        _NGINX_HAS_SITES=1
        : "${CB_NGINX_SITES_AVAILABLE:=$CB_NGINX_CONF_DIR/sites-available}"
        : "${CB_NGINX_SITES_ENABLED:=$CB_NGINX_CONF_DIR/sites-enabled}"
        ;;
    *)
        _NGINX_HAS_SITES=0
        : "${CB_NGINX_SITES_AVAILABLE:=$CB_NGINX_CONF_DIR/conf.d}"
        : "${CB_NGINX_SITES_ENABLED:=$CB_NGINX_CONF_DIR/conf.d}"
        ;;
esac

CB_CA="${CB_CA:-letsencrypt}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_EMAIL="${CB_EMAIL:-}"
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"
VALID_DOMAINS=()

# Reads existing certbot renewal config for a domain.
# Returns two lines on stdout: authenticator and webroot_path.
# Returns 1 if the renewal config does not exist.
_cb_read_certbot_renewal() {
    local domain="$1"
    local conf="/etc/letsencrypt/renewal/${domain}.conf"
    [[ -f "$conf" && -s "$conf" ]] || return 1

    local auth="" wrpath=""
    auth=$(grep -E '^\s*authenticator\s*=' "$conf" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')

    if [[ "$auth" == "webroot" ]]; then
        wrpath=$(awk '
            /^\[\[webroot\]\]/ { in_wr=1; next }
            /^\[/              { in_wr=0 }
            in_wr && /=/ {
                sub(/^[^=]*=\s*/, "")
                gsub(/[[:space:],]/, "")
                print
                exit
            }
        ' "$conf" 2>/dev/null)
        [[ -z "$wrpath" ]] && wrpath=$(grep -E '^\s*webroot_path\s*=' "$conf" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]' | tr -d ',')
    fi

    printf '%s\n%s\n' "$auth" "$wrpath"
    return 0
}

usage() {
    cat <<USAGE
nginx-certbot.sh - nginx + certbot webroot + Let's Encrypt / HARICA

Usage: $0 [OPTIONS]

  -t, --staging        Staging CA
  -y, --yes            Non-interactive
  -n, --dry-run        Simulation
  -v, --verbose        Debug
      --domain D       Domain (repeatable)
      --email E        Contact email
      --ca NAME        letsencrypt | harica | zerossl
      --acme-url URL   Custom ACME URL
      --webroot DIR    ACME webroot (default: autodetect from nginx root)
      --eab-kid KID
      --eab-hmac HMAC
      --no-firewall    Never automatically modify firewall
      --open-firewall  Explicitly allow firewall mutations (including HARICA)
      --set CB_X=Y     Advanced override of any CB_* option
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
            --webroot) [[ $# -ge 2 ]] || cb_die "--webroot requires a value"; shift; CB_NGINX_WEBROOT="$1" ;;
            --eab-kid) shift; CB_EAB_KID="$1" ;;
            --eab-hmac) shift; CB_EAB_HMAC="$1" ;;
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
stage_prepare() {
    cb_banner "Certberus / nginx / certbot"
    cb_require_root
    cb_hook_context nginx ""
    mkdir -p "$CB_LOG_DIR" "$CB_CERTBOT_HOOK_DIR" "$CB_STATE_DIR" 2>/dev/null
    # Detect nginx document root (if --webroot was not specified explicitly)
    if [[ -z "$CB_NGINX_WEBROOT" ]]; then
        CB_NGINX_WEBROOT=$(nginx -T 2>/dev/null \
            | awk '
            /^[[:space:]]*#/ { next }
            /\{/ { depth++ }
            /server[[:space:]]*\{/ { in_s=1; sd=depth; has80=0; r="" }
            in_s && depth==sd && /listen[[:space:]]/ && /80/ { has80=1 }
            in_s && depth==sd && /^[[:space:]]*root[[:space:]]/ { r=$2; gsub(/;/,"",r) }
            /\}/ { if (in_s && depth==sd && has80 && r) { print r; exit }; if (depth==sd) in_s=0; depth-- }
            ')
        [[ -z "$CB_NGINX_WEBROOT" ]] && CB_NGINX_WEBROOT="/var/www/html"
        cb_debug "Nginx document root: $CB_NGINX_WEBROOT"
    fi
    cb_run_hooks pre-install
}

stage_install_packages() {
    cb_sep
    local need=()
    cb_pkg_installed nginx || need+=(nginx)
    cb_pkg_installed certbot || need+=(certbot)
    # dnsutils (dig) is not strictly needed - getent handles A/AAAA; CAA is just a warning
    if (( ${#need[@]} > 0 )); then
        cb_log "Missing: ${need[*]}"
        cb_ask_yn "Install?" "Y/n" || cb_die "Aborting"
        cb_pkg_install "${need[@]}" || cb_die "Installation failed"
    else
        cb_ok "All packages are present"
    fi
    cb_run_hooks post-install
}

stage_snapshot() {
    cb_sep
    cb_run_hooks pre-snapshot
    # The snapshot also includes certbot state (/etc/letsencrypt) so rollback restores the original cert.
    # Non-existent paths are automatically skipped by cb_snapshot.
    cb_snapshot "$CB_NGINX_CONF_DIR" "nginx-pre-cert" \
        /etc/letsencrypt/live \
        /etc/letsencrypt/archive \
        /etc/letsencrypt/renewal \
        /etc/letsencrypt/accounts \
        >/dev/null
    # Firewall snapshot for rollback
    cb_firewall_snapshot >/dev/null
    cb_run_hooks post-snapshot
}

stage_detect_existing() {
    cb_sep
    # Detect other ACME clients
    for c in acme.sh dehydrated lego; do
        command -v "$c" >/dev/null 2>&1 && cb_warn "Found another ACME client: $c - possible conflict"
    done
    # Detect staging data
    if [[ -d /etc/letsencrypt/renewal ]] && [[ "$CB_STAGING" == "0" ]]; then
        if grep -rq 'acme-staging' /etc/letsencrypt/renewal/ 2>/dev/null; then
            cb_warn "Found staging certbot certificate in /etc/letsencrypt/"
            cb_warn "Will be overwritten during production renewal"
        fi
    fi
    # Detect other ssl_certificate paths
    if command -v nginx >/dev/null; then
        local current_certs
        current_certs=$(nginx -T 2>/dev/null | grep -E '^\s*ssl_certificate\s' | awk '{print $2}' | sort -u)
        [[ -n "$current_certs" ]] && cb_log "Current nginx ssl_certificate paths: $current_certs"
    fi
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
        # Detect from nginx server_name directives
        cb_log "Searching for domains in nginx configuration"
        local domains
        domains=$(nginx -T 2>/dev/null | \
            grep -E '^\s*server_name\s' | \
            sed -e 's/^\s*server_name//' -e 's/;//' | \
            tr ' ' '\n' | \
            grep -v '^_$' | grep -v '^$' | sort -u)
        if [[ -z "$domains" ]]; then
            cb_warn "nginx -T did not provide config, trying fallback grep over $CB_NGINX_CONF_DIR"
            domains=$(grep -RhsE '^\s*server_name\s' "$CB_NGINX_CONF_DIR" 2>/dev/null | \
                sed -e 's/^\s*server_name//' -e 's/;//' | \
                tr ' ' '\n' | grep -v '^_$' | grep -v '^$' | sort -u)
        fi
        for d in $domains; do
            [[ "$d" == \** ]] && continue
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
    cb_hook_context nginx "${VALID_DOMAINS[@]}"
}

stage_email() {
    if [[ -z "$CB_EMAIL" ]]; then
        CB_EMAIL=$(cb_ask_in "Contact email" "admin@$(hostname -d 2>/dev/null || echo example.com)")
    fi
    cb_validate_email "$CB_EMAIL" || cb_die "Invalid email: $CB_EMAIL"
}

# Detects orphaned /etc/letsencrypt/{live,archive}/DOMAIN/ and empty renewal confs
# that certbot would reject with "live/archive directory exists for ...".
# Returns 0 if state is valid (keep), 1 if cleaned up (or did not exist).
cb_cleanup_orphan_certbot_state() {
    local d="$1"
    local live="/etc/letsencrypt/live/$d"
    local arch="/etc/letsencrypt/archive/$d"
    local conf="/etc/letsencrypt/renewal/$d.conf"

    # Valid certbot state: all three exist, renewal conf is not empty,
    # archive has cert1.pem and symlinks in live point to archive.
    if [[ -f "$conf" && -s "$conf" && -d "$arch" && -e "$live/fullchain.pem" && ! -e "$live/.certberus-placeholder" ]]; then
        local target
        target=$(readlink -f "$live/fullchain.pem" 2>/dev/null)
        if [[ "$target" == "$arch/"* ]]; then
            return 0
        fi
        cb_warn "Cert for $d has unexpected symlinks (not pointing to archive/). Cleaning up."
    fi

    local cleaned=0
    if [[ -d "$live" ]]; then
        cb_warn "Orphaned /etc/letsencrypt/live/$d (missing renewal conf or archive, or is placeholder). Removing."
        rm -rf "$live"
        cleaned=1
    fi
    if [[ -d "$arch" ]]; then
        cb_warn "Orphaned /etc/letsencrypt/archive/$d. Removing."
        rm -rf "$arch"
        cleaned=1
    fi
    if [[ -f "$conf" ]] && ! [[ -s "$conf" ]]; then
        cb_warn "Empty /etc/letsencrypt/renewal/$d.conf. Removing."
        rm -f "$conf"
        cleaned=1
    fi
    return 0
}

# If an nginx vhost references a cert file that does not exist (broken state),
# generate a temporary self-signed placeholder. This allows nginx -t to pass and
# certbot to run. The placeholder is marked with .certberus-placeholder and is
# removed before the actual certbot request.
cb_ensure_cert_placeholder() {
    local d="$1"
    local live="/etc/letsencrypt/live/$d"
    local fc="$live/fullchain.pem"
    local pk="$live/privkey.pem"

    # Check whether nginx references this path at all.
    # `nginx -T` does not output config when syntax test fails (e.g. due to missing cert),
    # so we fall back to a direct grep of the config directory.
    local referenced=0
    if command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | grep -qF "$fc"; then
        referenced=1
    elif grep -rqF "$fc" "$CB_NGINX_CONF_DIR" 2>/dev/null; then
        referenced=1
    fi
    [[ $referenced -eq 1 ]] || return 0

    # If the cert exists and is readable - do nothing
    if [[ -e "$fc" && -e "$pk" ]] && openssl x509 -in "$fc" -noout 2>/dev/null; then
        return 0
    fi

    # If there is broken state from previous attempts, clean it up
    cb_cleanup_orphan_certbot_state "$d"

    cb_warn "Nginx vhost references missing $fc - generating temporary self-signed placeholder."
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping placeholder generation"; return 0; }

    mkdir -p "$live"
    # EC P-256 self-signed, 7 dni, s SAN
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 7 -keyout "$pk" -out "$fc" \
            -subj "/CN=$d" -addext "subjectAltName=DNS:$d" 2>/dev/null; then
        # Fallback for older openssl: RSA 2048
        openssl req -x509 -nodes -newkey rsa:2048 -days 7 \
            -keyout "$pk" -out "$fc" \
            -subj "/CN=$d" -addext "subjectAltName=DNS:$d" 2>/dev/null \
            || cb_die "Failed to generate self-signed placeholder for $d"
    fi
    chmod 600 "$pk"
    touch "$live/.certberus-placeholder"
    cb_ok "Placeholder installed: $fc (self-signed, 7 days)"
}

# Stage: for each VALID_DOMAIN - clean orphaned certbot state and deploy
# a placeholder if an nginx vhost references a missing cert.
stage_ensure_cert_placeholders() {
    cb_sep
    local d
    for d in "${VALID_DOMAINS[@]}"; do
        cb_ensure_cert_placeholder "$d"
    done
}

stage_firewall() {
    cb_firewall_ensure_http_https_for_acme
}

stage_nginx_acme_location() {
    cb_sep
    # Migration: remove remnants of old snippet approach (<=0.1.16)
    local snippet="/etc/nginx/snippets/certberus-acme.conf"
    if [[ -f "$snippet" ]]; then
        cb_log "Removing obsolete ACME snippet: $snippet"
        [[ "$CB_DRY_RUN" == "0" ]] && rm -f "$snippet"
    fi
    # Remove include lines from nginx config
    local f
    for f in "$CB_NGINX_SITES_ENABLED"/* "$CB_NGINX_CONF_DIR"/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep 'certberus-acme\.conf' "$f" 2>/dev/null; then >/dev/null
            cb_log "Removing obsolete include from $f"
            [[ "$CB_DRY_RUN" == "0" ]] && sed -i '/certberus-acme\.conf/d' "$f"
        fi
    done
    cb_ok "ACME webroot: $CB_NGINX_WEBROOT (nginx document root)"
}

stage_install_deploy_hook() {
    cb_sep
    local hook="$CB_CERTBOT_HOOK_DIR/certberus-nginx-reload.sh"
    cb_log "Installing deploy hook: $hook"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        cat > "$hook" <<'HOOK_EOF'
#!/bin/bash
# Certberus certbot deploy hook for nginx - generated, do not edit.
# Invoked by certbot after successful cert renewal.
LOG="/var/log/certberus/certbot-renewal.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
[[ -w "$(dirname "$LOG")" ]] || LOG="/dev/null"
TS="[$(date '+%F %T')]"
echo "$TS Renewed: $RENEWED_DOMAINS ($RENEWED_LINEAGE)" >> "$LOG" 2>/dev/null
command -v logger >/dev/null && logger -t certberus-nginx "renewal: $RENEWED_DOMAINS"

# Export to hook env
export CA_EVENT="renewed"
export CA_WEBSERVER="nginx"
export CA_PRIMARY_DOMAIN=$(echo "$RENEWED_DOMAINS" | awk '{print $1}')
export CA_DOMAIN_LIST="$RENEWED_DOMAINS"
export CA_CERT_PATH="$RENEWED_LINEAGE/fullchain.pem"
export CA_KEY_PATH="$RENEWED_LINEAGE/privkey.pem"
export CA_SOURCE="certbot"

# Run certberus hooks renewed.d and post-deploy.d
HOOK_TO="${CB_HOOK_TIMEOUT:-60}"
HAVE_TO=0; command -v timeout >/dev/null 2>&1 && HAVE_TO=1
for ev in renewed post-deploy; do
    D="/etc/certberus/hooks/${ev}.d"
    [[ -d "$D" ]] || continue
    for f in "$D"/*; do
        [[ -x "$f" ]] || continue
        case "$f" in *.example|*.bak|*.disabled) continue ;; esac
        if (( HAVE_TO )); then
            timeout "$HOOK_TO" "$f" >> "$LOG" 2>&1 || true
        else
            "$f" >> "$LOG" 2>&1 || true
        fi
    done
done

reload_nginx() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl reload nginx
    elif command -v service >/dev/null 2>&1; then
        service nginx reload
    elif command -v nginx >/dev/null 2>&1; then
        nginx -s reload
    else
        return 1
    fi
}

if nginx -t >/dev/null 2>&1; then
    if reload_nginx >/dev/null 2>&1; then
        echo "$TS nginx reload OK" >> "$LOG"
    else
        echo "$TS ERROR: nginx reload failed" >> "$LOG"
        exit 1
    fi
else
    echo "$TS ERROR: nginx -t failed, reload skipped" >> "$LOG"
    exit 1
fi
HOOK_EOF
        chmod +x "$hook"
    fi
    cb_ok "Deploy hook: $hook"
}

stage_issue_cert() {
    cb_sep
    cb_run_hooks pre-issue

    # Make sure nginx is running and listening on 80
    cb_svc_is_active nginx || {
        cb_log "Starting nginx"
        [[ "$CB_DRY_RUN" == "0" ]] && cb_svc_start nginx
    }
    [[ "$CB_DRY_RUN" == "0" ]] && nginx -s reload 2>/dev/null || true

    # URL
    local acme_url="$CB_ACME_URL"
    case "$CB_CA" in
        letsencrypt)
            [[ -z "$acme_url" && "$CB_STAGING" == "1" ]] && acme_url="https://acme-staging-v02.api.letsencrypt.org/directory"
            ;;
        harica)
            # HARICA/CESNET TCS provides a per-account ACME directory URL;
            # there is no universal fallback. We require explicit --acme-url or CB_ACME_URL_HARICA.
            [[ -z "$acme_url" ]] && acme_url="${CB_ACME_URL_HARICA:-}"
            CB_EAB_REQUIRED=1
            [[ -n "$acme_url" ]] || cb_die "CA harica requires --acme-url (per-account HARICA ACME directory URL), e.g. https://acme.harica.gr/<alias>/directory. Alternatively set CB_ACME_URL_HARICA in /etc/certberus/advanced.env."
            [[ "$acme_url" != *".../"* && "$acme_url" != *"VAS_"* && "$acme_url" != *"<"* ]] || cb_die "HARICA ACME URL looks like a placeholder: $acme_url"
            ;;
        zerossl)
            [[ -z "$acme_url" ]] && acme_url="${CB_ACME_URL_ZEROSSL:-https://acme.zerossl.com/v2/DV90}"
            CB_EAB_REQUIRED=1
            ;;
    esac

    # EAB validation
    if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
        [[ -n "$CB_EAB_KID" ]] || CB_EAB_KID=$(cb_ask_in "EAB KID" "")
        [[ -n "$CB_EAB_HMAC" ]] || CB_EAB_HMAC=$(cb_ask_secret "EAB HMAC")
        [[ -n "$CB_EAB_KID" && -n "$CB_EAB_HMAC" ]] || cb_die "CA $CB_CA requires EAB"
    fi

    # Common args for all certbot invocations
    local -a common_args=(--email "$CB_EMAIL" --agree-tos --no-eff-email \
                          --non-interactive --keep-until-expiring)
    [[ -n "$acme_url" ]] && common_args+=(--server "$acme_url")
    [[ "$CB_EAB_REQUIRED" == "1" ]] && common_args+=(--eab-kid "$CB_EAB_KID" --eab-hmac-key "$CB_EAB_HMAC")
    [[ "$CB_DRY_RUN" == "1" ]] && common_args+=(--dry-run)

    # Detect availability of certbot-nginx plugin (for new domains)
    local _cb_has_nginx_plugin=0
    if certbot plugins 2>/dev/null | grep 'nginx'; then >/dev/null
        _cb_has_nginx_plugin=1
    fi

    # Group domains by existing certbot authenticator.
    # Domains with the same (authenticator, webroot_path) go into one certbot invocation.
    # New domains (without renewal config) use --nginx if the plugin is available,
    # otherwise fall back to --webroot with CB_NGINX_WEBROOT.
    local -a group_keys=()
    declare -A domain_groups=()
    local d auth_info auth wrpath group_key
    for d in "${VALID_DOMAINS[@]}"; do
        if auth_info=$(_cb_read_certbot_renewal "$d"); then
            auth=$(printf '%s' "$auth_info" | sed -n '1p')
            wrpath=$(printf '%s' "$auth_info" | sed -n '2p')
        else
            auth=""
            wrpath=""
        fi
        if [[ -z "$auth" ]]; then
            if (( _cb_has_nginx_plugin )); then
                auth="nginx"
            else
                auth="webroot"
            fi
        fi
        [[ "$auth" == "webroot" && -z "$wrpath" ]] && wrpath="$CB_NGINX_WEBROOT"
        group_key="${auth}:${wrpath}"
        if [[ -z "${domain_groups[$group_key]:-}" ]]; then
            group_keys+=("$group_key")
        fi
        domain_groups["$group_key"]="${domain_groups[$group_key]:-} $d"
        cb_debug "Domain $d: authenticator=$auth webroot=$wrpath"
    done

    # Before the actual certbot request:
    #  - remove our self-signed placeholders (certbot would reject with "live directory exists")
    #  - clean orphaned certbot state from previous failures (empty renewal confs etc.)
    local dd
    for dd in "${VALID_DOMAINS[@]}"; do
        if [[ -e "/etc/letsencrypt/live/$dd/.certberus-placeholder" ]]; then
            cb_log "Removing placeholder /etc/letsencrypt/live/$dd/ before certbot request"
            rm -rf "/etc/letsencrypt/live/$dd" "/etc/letsencrypt/archive/$dd"
            rm -f  "/etc/letsencrypt/renewal/$dd.conf"
        else
            cb_cleanup_orphan_certbot_state "$dd" || true
        fi
    done

    # Issue certs for each group
    for group_key in "${group_keys[@]}"; do
        local group_auth="${group_key%%:*}"
        local group_wrpath="${group_key#*:}"
        local -a group_domains=(${domain_groups[$group_key]})

        local -a args=(certonly)
        case "$group_auth" in
            nginx)      args+=(--nginx) ;;
            standalone) args+=(--standalone) ;;
            *)          args+=(--webroot -w "$group_wrpath") ;;
        esac
        args+=("${common_args[@]}")

        # --cert-name fixes the certificate name to the primary domain
        local primary_d="${group_domains[0]}"
        args+=(--cert-name "$primary_d")
        if (( ${#group_domains[@]} > 1 )); then
            args+=(--expand)
        fi

        for d in "${group_domains[@]}"; do
            args+=(-d "$d")
        done

        # Detect CA change or staging->production transition
        local live_cert="/etc/letsencrypt/live/$primary_d/fullchain.pem"
        if [[ -f "$live_cert" ]]; then
            local cur_issuer force_renew=0
            cur_issuer=$(openssl x509 -in "$live_cert" -noout -issuer 2>/dev/null || true)
            # Staging->production: existing cert is staging but we want production
            if [[ "$CB_STAGING" != "1" ]] && printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
                cb_warn "Existing cert for $primary_d is staging (issuer: $cur_issuer). Forcing --force-renewal for production."
                force_renew=1
            fi
            # Production->staging: existing cert is production but we want staging
            if [[ "$CB_STAGING" == "1" ]] && ! printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
                cb_warn "Existing cert for $primary_d is production, but we want staging. Forcing --force-renewal."
                force_renew=1
                args+=(--break-my-certs)
            fi
            # CA change (e.g. LE->HARICA)
            if (( force_renew == 0 )); then
                local wanted_issuer_re=""
                case "$CB_CA" in
                    letsencrypt) wanted_issuer_re='Let.?s Encrypt|STAGING|FAKE' ;;
                    harica)      wanted_issuer_re='HARICA|Hellenic|GEANT|CESNET' ;;
                    zerossl)     wanted_issuer_re='ZeroSSL' ;;
                esac
                if [[ -n "$wanted_issuer_re" && -n "$cur_issuer" ]] && ! printf '%s' "$cur_issuer" | grep -qiE "$wanted_issuer_re"; then
                    cb_warn "Existing cert for $primary_d is from a different CA (issuer: $cur_issuer). Forcing --force-renewal."
                    force_renew=1
                fi
            fi
            (( force_renew )) && args+=(--force-renewal)
        fi

        cb_log "certbot ${args[*]}"
        if ! cb_retry "${CB_RETRY_COUNT:-3}" "${CB_RETRY_DELAY:-10}" cb_certbot_issue "$primary_d" "${args[@]}"; then
            cb_die "certbot failed for: ${group_domains[*]}"
        fi
        cb_ok "Certificate issued: ${group_domains[*]} (authenticator=$group_auth)"
        cb_hook_set_cert "/etc/letsencrypt/live/$primary_d/fullchain.pem" \
                        "/etc/letsencrypt/live/$primary_d/privkey.pem" \
                        "$CB_CA" "certbot"
    done

    export CA_SOURCE="certbot"
    cb_run_hooks post-issue
}

stage_inject_nginx_ssl() {
    cb_sep
    # This is optional - the script can just issue the cert and leave nginx config to the admin.
    # Below is a minimal addition of ssl_certificate directives if missing.
    local primary="${VALID_DOMAINS[0]}"
    local live_dir="/etc/letsencrypt/live/$primary"
    if [[ ! -d "$live_dir" && "$CB_DRY_RUN" == "0" ]]; then
        cb_warn "Not certain $live_dir exists - skipping injection"
        return 0
    fi
    cb_log "HTTPS configuration for nginx (paths: $live_dir)"
    cb_log "Tip: for full configuration, edit sites-available/ manually - this script only issues the cert."
    cb_log "Cert will be automatically reloaded on renewal via deploy hook."
}

stage_enable_timer() {
    # certbot.timer (systemd)
    if systemctl list-unit-files 2>/dev/null | grep '^certbot\.timer'; then >/dev/null
        systemctl enable --now certbot.timer >/dev/null 2>&1 && cb_ok "certbot.timer enabled"
    elif systemctl list-unit-files 2>/dev/null | grep '^snap.certbot.renew.timer'; then >/dev/null
        systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 && cb_ok "snap certbot.renew.timer enabled"
    fi
}

stage_preflight() {
    local synerr
    synerr=$(nginx -t 2>&1)
    if [[ $? -eq 0 ]]; then
        _CB_NGINX_BASELINE_OK=1
    else
        _CB_NGINX_BASELINE_OK=0
    fi
    _CB_NGINX_BASELINE_CERT_ONLY=0
    cb_preflight_nginx || true
    # If nginx -t is already failing NOW (before any of our actions),
    # we refuse to continue. Otherwise subsequent stages would create a snippet,
    # deploy hook, modified vhost etc. and only test_reload would catch it later
    # - which means unnecessary system modifications (BUG #18b).
    if [[ "${_CB_NGINX_BASELINE_OK:-1}" == "0" ]]; then
        if cb_nginx_error_is_missing_cert "$synerr"; then
            _CB_NGINX_BASELINE_CERT_ONLY=1
            cb_warn "nginx -t fails due to missing cert/key file; proceeding to placeholder self-signed cert."
            return 0
        fi
        cb_die "nginx -t fails at baseline check. Fix the broken vhost (see preflight warnings) and run again. No changes were made."
    fi
}

cb_nginx_error_is_missing_cert() {
    local text="$1"
    printf '%s\n' "$text" | grep -qiE 'cannot load certificate|BIO_new_file\(\) failed|SSL_CTX_use_PrivateKey_file|No such file or directory.*(ssl_certificate|/etc/letsencrypt|fullchain|privkey|\.pem)'
}

stage_test_reload() {
    cb_sep
    cb_run_hooks pre-reload
    local test_out test_rc
    test_out=$(nginx -t 2>&1); test_rc=$?
    printf '%s\n' "$test_out" | tee -a "$CB_LOG_FILE"
    if (( test_rc != 0 )); then
        if [[ "$CB_DRY_RUN" == "1" && "${_CB_NGINX_BASELINE_CERT_ONLY:-0}" == "1" ]] && cb_nginx_error_is_missing_cert "$test_out"; then
            cb_warn "[dry-run] nginx -t still fails due to missing cert; in a real run Certberus would generate a placeholder before reload."
            return 0
        fi
        # Baseline was already failing at preflight - the error is not ours.
        if [[ "${_CB_NGINX_BASELINE_OK:-1}" == "0" && "${_CB_NGINX_BASELINE_CERT_ONLY:-0}" != "1" ]]; then
            cb_error "nginx -t has been failing from the start (broken vhost outside certberus). Fix and retry."
            cb_die "No changes were made."
        fi
        # If we have not changed anything relevant yet, the problem is not in the cert subsystem.
        if [[ "${_CB_MODIFIED_CONFIG:-0}" == "0" ]]; then
            cb_error "nginx -t started failing outside our changes (see preflight warnings)."
            cb_die "Certberus will not continue. No critical changes were made."
        fi
        cb_error "nginx -t failed after our changes"
        if [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]]; then
            cb_snapshot_restore "$CB_LAST_SNAPSHOT"
            nginx -t 2>&1 | tee -a "$CB_LOG_FILE" || cb_die "nginx -t still fails after rollback"
            cb_die "Rollback done. Original state preserved, cert is not deployed."
        else
            cb_rollback_hint
            cb_die "nginx -t failed - ROLLBACK"
        fi
    fi
    cb_ok "nginx -t OK"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        cb_svc_is_active nginx || cb_svc_start nginx
        if ! cb_svc_reload nginx; then
            cb_error "nginx reload failed"
            if [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]]; then
                cb_snapshot_restore "$CB_LAST_SNAPSHOT"
                cb_svc_reload nginx || cb_die "nginx is broken even after rollback"
                cb_die "Rollback done."
            fi
            cb_die "nginx reload failed"
        fi
    fi
    cb_ok "nginx reload OK"
    cb_mark_installed "nginx-certbot"
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
    run_stage install_packages
    run_stage preflight
    run_stage snapshot
    run_stage detect_existing
    run_stage find_domains
    run_stage email
    run_stage firewall
    run_stage nginx_acme_location
    run_stage install_deploy_hook
    run_stage ensure_cert_placeholders
    run_stage test_reload   # first nginx config test (before issue)
    run_stage issue_cert
    _CB_MODIFIED_CONFIG=1
    run_stage inject_nginx_ssl
    run_stage enable_timer
    run_stage test_reload
    cb_sep
    cb_ok "Done. Domains: ${VALID_DOMAINS[*]}"
}
main "$@"
