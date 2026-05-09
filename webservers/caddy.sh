#!/bin/bash
# certberus/webservers/caddy.sh
# Caddy - native ACME (no certbot, like Apache mod_md)
#
# Strategy:
#   Caddy has its own ACME client, just configure:
#     - global email
#     - acme_ca (staging/production/HARICA URL)
#     - acme_eab (for HARICA/ZeroSSL)
#   Caddy handles issue, renew, deploy itself. Certberus only configures and monitors.
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

: "${CB_CADDY_CONFIG:=/etc/caddy/Caddyfile}"
: "${CB_CADDY_DATA_DIR:=}"

CB_CA="${CB_CA:-letsencrypt}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_EMAIL="${CB_EMAIL:-}"
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"
VALID_DOMAINS=()

usage() {
    cat <<USAGE
caddy.sh - Caddy native ACME (zero-config TLS)

Usage: $0 [OPTIONS]

  -t, --staging        Staging CA
  -y, --yes            Non-interactive
  -n, --dry-run        Simulation
  -v, --verbose        Debug
      --domain D       Domain (repeatable)
      --email E        Contact email
      --ca NAME        letsencrypt | harica | zerossl
      --acme-url URL   Custom ACME URL
      --eab-kid KID
      --eab-hmac HMAC
      --no-firewall    Never modify firewall automatically
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
    cb_banner "Certberus / Caddy / native ACME"
    cb_require_root
    cb_hook_context caddy ""
    mkdir -p "$CB_LOG_DIR" "$CB_STATE_DIR" 2>/dev/null
    cb_run_hooks pre-install
}

stage_detect_caddy() {
    cb_sep
    if ! command -v caddy >/dev/null 2>&1; then
        cb_die "Caddy not found. Install Caddy from https://caddyserver.com/docs/install"
    fi
    local ver
    ver=$(caddy version 2>/dev/null | head -1)
    cb_ok "Caddy found: $ver"

    # Check systemd service
    if systemctl list-unit-files 2>/dev/null | grep '^caddy\.service'; then >/dev/null
        cb_ok "caddy.service found"
    else
        cb_warn "caddy.service not found - you must restart manually after configuration"
    fi

    # Caddy config
    if [[ ! -f "$CB_CADDY_CONFIG" ]]; then
        cb_warn "Caddyfile not found: $CB_CADDY_CONFIG"
        for p in /etc/caddy/Caddyfile /etc/caddy/caddy.conf /opt/caddy/Caddyfile; do
            if [[ -f "$p" ]]; then
                CB_CADDY_CONFIG="$p"
                cb_ok "Found: $CB_CADDY_CONFIG"
                break
            fi
        done
        [[ -f "$CB_CADDY_CONFIG" ]] || cb_die "Caddyfile not found"
    fi
    cb_log "Caddyfile: $CB_CADDY_CONFIG"

    # Caddy data directory
    if [[ -z "$CB_CADDY_DATA_DIR" ]]; then
        # Caddy stores certs in XDG_DATA_HOME or /var/lib/caddy/.local/share/caddy
        for p in /var/lib/caddy/.local/share/caddy \
                 /root/.local/share/caddy \
                 /home/caddy/.local/share/caddy; do
            [[ -d "$p" ]] && { CB_CADDY_DATA_DIR="$p"; break; }
        done
        [[ -z "$CB_CADDY_DATA_DIR" ]] && CB_CADDY_DATA_DIR="/var/lib/caddy/.local/share/caddy"
    fi
    cb_log "Data dir: $CB_CADDY_DATA_DIR"
}

stage_install_packages() {
    cb_sep
    if command -v caddy >/dev/null 2>&1; then
        cb_ok "Caddy is installed"
    else
        cb_die "Caddy is not installed. See https://caddyserver.com/docs/install"
    fi
    cb_run_hooks post-install
}

stage_snapshot() {
    cb_sep
    cb_run_hooks pre-snapshot
    local caddy_dir
    caddy_dir=$(dirname "$CB_CADDY_CONFIG")
    cb_snapshot "$caddy_dir" "caddy-pre-cert" \
        "$CB_CADDY_DATA_DIR" \
        >/dev/null
    cb_firewall_snapshot >/dev/null
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
        cb_log "Looking for domains in Caddyfile..."
        local domains=""
        # Parse site blocks from Caddyfile: lines starting with a domain followed by {
        # or domains on a line before a block. Caddy format:
        #   example.com {
        #   example.com, www.example.com {
        #   example.com:443 {
        if [[ -f "$CB_CADDY_CONFIG" ]]; then
            domains=$(awk '
                /^\s*#/ { next }
                /^\s*\{/ { next }
                /\{/ {
                    # Everything before { are site addresses
                    sub(/\{.*/, "")
                    gsub(/,/, " ")
                    n = split($0, parts)
                    for (i=1; i<=n; i++) {
                        addr = parts[i]
                        # Remove port
                        sub(/:[0-9]+$/, "", addr)
                        # Remove protocol
                        sub(/^https?:\/\//, "", addr)
                        # Remove trailing slash
                        sub(/\/.*$/, "", addr)
                        # Skip wildcard
                        if (addr ~ /^\*/) next
                        # Valid FQDN
                        if (addr ~ /^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$/ && addr ~ /\./) {
                            print addr
                        }
                    }
                }
            ' "$CB_CADDY_CONFIG" 2>/dev/null | sort -u)
        fi

        if [[ -z "$domains" ]]; then
            cb_warn "No domains found in $CB_CADDY_CONFIG"
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
    cb_hook_context caddy "${VALID_DOMAINS[@]}"
}

stage_email() {
    if [[ -z "$CB_EMAIL" ]]; then
        CB_EMAIL=$(cb_ask_in "Contact email" "admin@$(hostname -d 2>/dev/null || echo example.com)")
    fi
    cb_validate_email "$CB_EMAIL" || cb_die "Invalid email: $CB_EMAIL"
}

stage_configure_acme() {
    cb_sep
    cb_log "Configuring ACME in Caddyfile..."
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping configuration"; return 0; }

    # Determine ACME URL
    local acme_url="$CB_ACME_URL"
    case "$CB_CA" in
        letsencrypt)
            if [[ "$CB_STAGING" == "1" ]]; then
                acme_url="https://acme-staging-v02.api.letsencrypt.org/directory"
            else
                acme_url=""  # Caddy default is LE production
            fi
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

    # Generate global options snippet
    local global_opts=""
    global_opts+="    email $CB_EMAIL"$'\n'
    [[ -n "$acme_url" ]] && global_opts+="    acme_ca $acme_url"$'\n'
    if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
        global_opts+="    acme_eab {"$'\n'
        global_opts+="        key_id $CB_EAB_KID"$'\n'
        global_opts+="        mac_key $CB_EAB_HMAC"$'\n'
        global_opts+="    }"$'\n'
    fi

    # Check whether Caddyfile already has a global options block
    # Format: { ... } at the beginning of the file (before any site block)
    local config_content
    config_content=$(cat "$CB_CADDY_CONFIG")

    # Certberus-managed snippet
    local snippet_file
    snippet_file="$(dirname "$CB_CADDY_CONFIG")/certberus-acme.caddy"

    cb_log "Writing ACME configuration: $snippet_file"
    cat > "$snippet_file" <<SNIPPET_EOF
# Certberus ACME configuration - generated, do not edit.
{
$global_opts}
SNIPPET_EOF

    # Check if Caddyfile imports our snippet
    if ! grep 'import certberus-acme.caddy' "$CB_CADDY_CONFIG" 2>/dev/null; then >/dev/null
        # Add import at the beginning of Caddyfile (before the first site block)
        cb_log "Adding 'import certberus-acme.caddy' to $CB_CADDY_CONFIG"
        local tmp_cf; tmp_cf=$(mktemp)
        {
            echo "import certberus-acme.caddy"
            echo ""
            cat "$CB_CADDY_CONFIG"
        } > "$tmp_cf"
        mv -f "$tmp_cf" "$CB_CADDY_CONFIG"
    fi

    cb_ok "ACME configuration written"
}

stage_firewall() {
    cb_firewall_ensure_http_https_for_acme
}

stage_test_reload() {
    cb_sep
    cb_run_hooks pre-reload
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping Caddy reload"; return 0; }

    # Validate Caddyfile
    local validate_out validate_rc
    local caddy_dir
    caddy_dir=$(dirname "$CB_CADDY_CONFIG")
    validate_out=$(cd "$caddy_dir" && caddy validate --config "$CB_CADDY_CONFIG" 2>&1); validate_rc=$?
    if (( validate_rc != 0 )); then
        cb_error "caddy validate failed:"
        printf '%s\n' "$validate_out" | tee -a "$CB_LOG_FILE"
        cb_rollback_hint
        cb_die "Caddyfile validation failed"
    fi
    cb_ok "caddy validate OK"

    # Reload or restart
    if cb_svc_is_active caddy; then
        if caddy reload --config "$CB_CADDY_CONFIG" 2>>"$CB_LOG_FILE"; then
            cb_ok "caddy reload OK"
        elif cb_svc_reload caddy; then
            cb_ok "systemctl reload caddy OK"
        else
            cb_warn "caddy reload failed, trying restart..."
            cb_svc_restart caddy || cb_die "Caddy restart failed"
            cb_ok "caddy restart OK"
        fi
    else
        cb_log "Caddy is not running, starting..."
        cb_svc_start caddy || cb_die "Caddy start failed"
        cb_ok "Caddy started"
    fi
    cb_mark_installed "caddy"
    cb_run_hooks post-reload
}

stage_verify_cert() {
    cb_sep
    [[ "$CB_DRY_RUN" == "1" ]] && { cb_log "[dry-run] skipping verification"; return 0; }

    local primary="${VALID_DOMAINS[0]}"
    local timeout_s="${CB_POST_ISSUE_TIMEOUT:-120}"
    cb_log "Waiting for TLS cert for $primary (max ${timeout_s}s)..."

    local waited=0 step=5
    while (( waited < timeout_s )); do
        local live_cert
        live_cert=$(echo | timeout 5 openssl s_client -servername "$primary" -connect "$primary:443" </dev/null 2>/dev/null)
        if [[ -n "$live_cert" ]]; then
            local issuer
            issuer=$(printf '%s\n' "$live_cert" | openssl x509 -noout -issuer 2>/dev/null || true)
            if [[ -n "$issuer" ]]; then
                # Check that it is not a Caddy dummy cert
                if printf '%s' "$issuer" | grep -qiE 'Caddy.*Local'; then
                    cb_debug "Still Caddy Local cert, waiting for ACME..."
                else
                    cb_ok "TLS cert active for $primary"
                    printf '%s\n' "$live_cert" | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
                    cb_hook_set_cert "" "" "$CB_CA" "caddy"
                    cb_run_hooks post-issue
                    return 0
                fi
            fi
        fi
        sleep "$step"
        waited=$(( waited + step ))
    done

    cb_warn "Cert did not complete within ${timeout_s}s. Caddy should obtain the cert in the background."
    cb_log "Watch: journalctl -u caddy -f"
    cb_run_hooks post-issue
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
    run_stage detect_caddy
    run_stage install_packages
    run_stage snapshot
    run_stage find_domains
    run_stage email
    run_stage configure_acme
    run_stage firewall
    run_stage test_reload
    run_stage verify_cert
    cb_sep
    cb_ok "Done. Domains: ${VALID_DOMAINS[*]}"
    cb_log "Log: $CB_LOG_FILE"
    [[ "$CB_STAGING" == "1" ]] && cb_warn "STAGING mode - cert is not trusted in browsers"
}
main "$@"
