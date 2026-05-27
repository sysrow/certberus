#!/bin/bash
# certberus/webservers/certbot-only.sh
# Generic certbot module for services that are NOT Apache/nginx/Tomcat.
# Usage: Jetty (Shibboleth IdP), HAProxy, Postfix, Dovecot, custom app...
#
# Strategy:
#   1. certbot certonly (webroot / standalone) - no webserver configuration
#   2. Certbot renewal timer takes care of automatic renewal
#
# issue-only "only issues": by default it obtains the cert and stops. Deployment
# (copy, conversion, reload) is the job of certbot's own deploy hooks in
# /etc/letsencrypt/renewal-hooks/deploy/, which certbot runs on issuance and on
# every renewal - no certberus involvement needed. Pass --hook "CMD" to register
# one inline, or drop a script into that directory yourself.
#
# Opt-in: --enable-hooks brings back certberus' own hook system (pre/post-issue,
# renewed.d, ...) plus a bridge deploy hook, for users who prefer it.
#
# Cert resides in /etc/letsencrypt/live/DOMAIN/ (standard certbot layout).
# This module NEVER configures any webserver, touches the firewall, or reloads services.
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

: "${CB_CERTBOT_ONLY_WEBROOT:=}"
: "${CB_CERTBOT_HOOK_DIR:=/etc/letsencrypt/renewal-hooks/deploy}"

CB_CA="${CB_CA:-letsencrypt}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_EMAIL="${CB_EMAIL:-}"
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"
# issue-only is "only issue" by default: certberus does NOT touch its own hook
# dirs and does NOT install a certbot bridge hook. Opt in with --enable-hooks.
CB_ENABLE_HOOKS="${CB_ENABLE_HOOKS:-0}"
# Optional inline command passed straight to certbot as --deploy-hook (native;
# runs on issuance and every renewal). Independent of CB_ENABLE_HOOKS.
CB_CERTBOT_DEPLOY_HOOK="${CB_CERTBOT_DEPLOY_HOOK:-}"
VALID_DOMAINS=()

# Run a certberus hook event only when the user opted in with --enable-hooks.
# Without it, issue-only stays pure: obtain the cert and nothing else.
_cb_only_run_hooks() {
    [[ "${CB_ENABLE_HOOKS:-0}" == "1" ]] || return 0
    cb_run_hooks "$@"
}

usage() {
    cat <<USAGE
certbot-only.sh - generic certbot (no webserver configuration)

For services like Jetty, HAProxy, Postfix, Dovecot, custom app.
issue-only obtains the cert and stops. Deployment is left to certbot.

Usage: $0 [OPTIONS]

  -t, --staging        Staging CA
  -y, --yes            Non-interactive
  -n, --dry-run        Dry run
  -v, --verbose        Debug
      --domain D       Domain (repeatable, REQUIRED)
      --email E        Contact email
      --ca NAME        letsencrypt | harica | zerossl
      --acme-url URL   Custom ACME directory URL
      --webroot DIR    ACME webroot (uses --webroot instead of --standalone)
      --eab-kid KID
      --eab-hmac HMAC
      --hook "CMD"     Register CMD as certbot's native --deploy-hook. Runs on
                       issuance and every renewal. Works on its own.
      --enable-hooks   Bring back certberus' own hook system (pre/post-issue,
                       renewed.d, ...) plus a bridge deploy hook. Separate from
                       --hook; off by default.
      --set CB_X=Y     Advanced override of any CB_* option
  -h, --help

Certificate obtaining strategy:
  1. With --webroot: certbot certonly --webroot (no port 80 binding)
  2. Without --webroot: certbot certonly --standalone (requires free port 80)
  3. With EAB (HARICA/ZeroSSL): --webroot is recommended

Deployment (default): certbot runs every executable in
/etc/letsencrypt/renewal-hooks/deploy/ after issuance and on each renewal, with
\$RENEWED_LINEAGE and \$RENEWED_DOMAINS set. Install the cert into a service there:
  cat > /etc/letsencrypt/renewal-hooks/deploy/10-myservice.sh <<'SH'
  #!/bin/bash
  install -m 0644 "\$RENEWED_LINEAGE/fullchain.pem" /etc/myservice/fullchain.pem
  install -m 0600 "\$RENEWED_LINEAGE/privkey.pem"   /etc/myservice/privkey.pem
  systemctl reload myservice
  SH
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/10-myservice.sh
Or pass the same one-liner via --hook "...". With --enable-hooks, certberus'
post-issue.d/ and renewed.d/ run instead (\$CA_CERT_PATH, \$CA_KEY_PATH, \$CA_PRIMARY_DOMAIN).
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
            --webroot) [[ $# -ge 2 ]] || cb_die "--webroot requires a value"; shift; CB_CERTBOT_ONLY_WEBROOT="$1" ;;
            --eab-kid) shift; CB_EAB_KID="$1" ;;
            --eab-hmac) shift; CB_EAB_HMAC="$1" ;;
            --enable-hooks) CB_ENABLE_HOOKS=1 ;;
            --hook) [[ $# -ge 2 ]] || cb_die "--hook requires a command"; shift; CB_CERTBOT_DEPLOY_HOOK="$1" ;;
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
    cb_banner "Certberus / certbot-only (generic)"
    cb_require_root
    cb_hook_context certbot-only ""
    mkdir -p "$CB_LOG_DIR" "$CB_STATE_DIR" "$CB_CERTBOT_HOOK_DIR" 2>/dev/null
    _cb_only_run_hooks pre-install
}

stage_install_packages() {
    cb_sep
    if ! cb_pkg_installed certbot && ! command -v certbot >/dev/null 2>&1; then
        cb_log "Missing: certbot"
        cb_ask_yn "Install certbot?" "Y/n" || cb_die "Aborting"
        cb_pkg_install certbot || cb_die "certbot installation failed"
    else
        cb_ok "certbot is present"
    fi
    _cb_only_run_hooks post-install
}

stage_snapshot() {
    cb_sep
    _cb_only_run_hooks pre-snapshot
    cb_snapshot /etc/letsencrypt "certbot-only-pre-cert" >/dev/null || true
    _cb_only_run_hooks post-snapshot
}

stage_find_domains() {
    cb_sep
    if [[ -z "$CB_DOMAINS" ]]; then
        local fqdn; fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null)
        if [[ "$fqdn" == *.* ]]; then
            cb_warn "No domain specified. Hostname is: $fqdn"
            if cb_ask_yn "Use $fqdn?" "Y/n"; then
                CB_DOMAINS="$fqdn"
            fi
        fi
        [[ -z "$CB_DOMAINS" ]] && cb_die "certbot-only requires explicit --domain (no webserver to detect from)."
    fi
    local d _seen=""
    for d in $CB_DOMAINS; do
        cb_validate_domain "$d" || { cb_warn "Ignoring invalid domain: $d"; continue; }
        [[ " $_seen " == *" $d "* ]] && continue
        VALID_DOMAINS+=("$d")
        _seen="$_seen $d"
    done
    (( ${#VALID_DOMAINS[@]} > 0 )) || cb_die "No valid domain"
    cb_hook_context certbot-only "${VALID_DOMAINS[@]}"
    cb_ok "Domains: ${VALID_DOMAINS[*]}"
}

stage_email() {
    if [[ -z "$CB_EMAIL" ]]; then
        CB_EMAIL=$(cb_ask_in "Contact email" "admin@$(hostname -d 2>/dev/null || echo example.com)")
    fi
    cb_validate_email "$CB_EMAIL" || cb_die "Invalid email: $CB_EMAIL"
}

stage_install_deploy_hook() {
    cb_sep
    local hook="$CB_CERTBOT_HOOK_DIR/certberus-certbot-only-hook.sh"

    # Default (issue-only): do NOT install the bridge. Deployment is certbot's
    # job via its native deploy hooks. Only install when the user opted in.
    if [[ "${CB_ENABLE_HOOKS:-0}" != "1" ]]; then
        cb_debug "certberus hooks disabled (issue-only default); not installing bridge deploy hook"
        # Migration: a bridge from an older certberus version may still be on
        # disk and would keep dispatching into certberus hooks on renewal.
        if [[ -f "$hook" ]]; then
            cb_warn "Bridge hook from an older certberus version is present: $hook"
            cb_warn "  issue-only no longer manages certberus hooks by default. Either:"
            cb_warn "    - pass --enable-hooks to keep using certberus hook dirs, or"
            cb_warn "    - remove it to go fully native: rm '$hook'"
        fi
        return 0
    fi

    cb_log "Installing certbot deploy hook: $hook"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        cat > "$hook" <<'HOOK_EOF'
#!/bin/bash
# Certberus certbot-only deploy hook - generated, do not edit.
# Executed by certbot after successful certificate renewal.
# Does not restart any service - that is handled by your hooks in post-issue.d / renewed.d.
LOG="/var/log/certberus/certbot-renewal.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
[[ -w "$(dirname "$LOG")" ]] || LOG="/dev/null"
TS="[$(date '+%F %T')]"
echo "$TS Renewed (certbot-only): $RENEWED_DOMAINS ($RENEWED_LINEAGE)" >> "$LOG" 2>/dev/null
command -v logger >/dev/null && logger -t certberus-certbot-only "renewal: $RENEWED_DOMAINS"

export CA_EVENT="renewed"
export CA_WEBSERVER="certbot-only"
export CA_PRIMARY_DOMAIN=$(echo "$RENEWED_DOMAINS" | awk '{print $1}')
export CA_DOMAIN_LIST="$RENEWED_DOMAINS"
export CA_CERT_PATH="$RENEWED_LINEAGE/fullchain.pem"
export CA_KEY_PATH="$RENEWED_LINEAGE/privkey.pem"
export CA_SOURCE="certbot"

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
exit 0
HOOK_EOF
        chmod +x "$hook"
    fi
    cb_ok "Deploy hook: $hook"
}

_cb_port80_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 'sport = :80' 2>/dev/null | grep ':80' && return 0 >/dev/null
    elif command -v fuser >/dev/null 2>&1; then
        fuser 80/tcp >/dev/null 2>&1 && return 0
    fi
    return 1
}

stage_firewall() {
    cb_firewall_ensure_http_https_for_acme
}

stage_issue_cert() {
    cb_sep
    _cb_only_run_hooks pre-issue

    # Certificate obtaining strategy
    local auth_mode=""
    if [[ -n "$CB_CERTBOT_ONLY_WEBROOT" ]]; then
        auth_mode="webroot"
        mkdir -p "$CB_CERTBOT_ONLY_WEBROOT/.well-known/acme-challenge" 2>/dev/null
        cb_log "Mode: webroot ($CB_CERTBOT_ONLY_WEBROOT)"
    elif _cb_port80_in_use; then
        # Auto-detect webroot from the running webserver so the user does not
        # have to specify it manually.
        local _detected_root=""
        if command -v nginx >/dev/null 2>&1; then
            local _ngx; _ngx=$(nginx -T 2>/dev/null)
            # Prefer the root that actually serves the ACME challenge (reverse
            # proxies keep it in a location block, not at server level).
            _detected_root=$(printf '%s\n' "$_ngx" | cb_nginx_acme_webroot)
            # Fall back to a server-level root in a server that listens on :80.
            if [[ -z "$_detected_root" ]]; then
                _detected_root=$(printf '%s\n' "$_ngx" | awk '
                    /^[[:space:]]*#/ { next }
                    /\{/ { depth++ }
                    /server[[:space:]]*\{/ { in_s=1; sd=depth; has80=0; r="" }
                    in_s && depth==sd && /listen[[:space:]]/ && /80/ { has80=1 }
                    in_s && depth==sd && /^[[:space:]]*root[[:space:]]/ { r=$2; gsub(/;/,"",r) }
                    /\}/ { if (in_s && depth==sd && has80 && r) { print r; exit }
                           if (depth==sd) in_s=0; depth-- }
                ' 2>/dev/null)
            fi
        fi
        if [[ -z "$_detected_root" ]]; then
            for _ac in apache2ctl apachectl; do
                command -v "$_ac" >/dev/null 2>&1 || continue
                _detected_root=$("$_ac" -S 2>/dev/null | awk '/DocumentRoot/ {print $2; exit}')
                [[ -n "$_detected_root" ]] && break
            done
        fi
        # Only trust an absolute path to an existing directory. Otherwise the
        # detection misfired (a reverse-proxy server block with no 'root', or a
        # label such as "DocumentRoot:") and we must NOT bake a bogus
        # webroot_path into certbot's renewal config - it would silently break
        # on the first renewal that actually needs an HTTP-01 fetch.
        if [[ -n "$_detected_root" && ( "$_detected_root" != /* || ! -d "$_detected_root" ) ]]; then
            cb_warn "Ignoring implausible auto-detected webroot: '$_detected_root'"
            _detected_root=""
        fi
        if [[ -n "$_detected_root" ]]; then
            CB_CERTBOT_ONLY_WEBROOT="$_detected_root"
            auth_mode="webroot"
            mkdir -p "$CB_CERTBOT_ONLY_WEBROOT/.well-known/acme-challenge" 2>/dev/null
            cb_log "Mode: webroot (auto-detected: $CB_CERTBOT_ONLY_WEBROOT)"
        elif cb_has_tty; then
            local _wr
            _wr=$(cb_ask_in "Port 80 is in use. Webroot dir for ACME challenge" "/var/www/html")
            CB_CERTBOT_ONLY_WEBROOT="$_wr"
            auth_mode="webroot"
            mkdir -p "$CB_CERTBOT_ONLY_WEBROOT/.well-known/acme-challenge" 2>/dev/null
            cb_log "Mode: webroot ($CB_CERTBOT_ONLY_WEBROOT)"
        else
            cb_die "Port 80 is in use. Specify --webroot <dir> served by the running webserver."
        fi
    else
        auth_mode="standalone"
        cb_log "Mode: standalone (port 80 is free)"
    fi

    # ACME URL
    local acme_url="$CB_ACME_URL"
    case "$CB_CA" in
        letsencrypt)
            [[ -z "$acme_url" && "$CB_STAGING" == "1" ]] && acme_url="https://acme-staging-v02.api.letsencrypt.org/directory"
            ;;
        harica)
            [[ -z "$acme_url" ]] && acme_url="${CB_ACME_URL_HARICA:-}"
            CB_EAB_REQUIRED=1
            [[ -n "$acme_url" ]] || cb_die "CA harica requires per-account --acme-url (e.g. https://acme.harica.gr/<alias>/directory)."
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
        [[ -n "$CB_EAB_KID" && -n "$CB_EAB_HMAC" ]] || cb_die "CA $CB_CA requires EAB KID and HMAC"
    fi

    # Common args
    local -a common_args=(--email "$CB_EMAIL" --agree-tos --no-eff-email \
                          --non-interactive --keep-until-expiring)
    [[ -n "$acme_url" ]] && common_args+=(--server "$acme_url")
    [[ "$CB_EAB_REQUIRED" == "1" ]] && common_args+=(--eab-kid "$CB_EAB_KID" --eab-hmac-key "$CB_EAB_HMAC")
    [[ "$CB_DRY_RUN" == "1" ]] && common_args+=(--dry-run)
    # Inline native deploy hook: certbot saves it into the renewal config, so it
    # runs now and on every future renewal - no certberus machinery involved.
    [[ -n "$CB_CERTBOT_DEPLOY_HOOK" ]] && common_args+=(--deploy-hook "$CB_CERTBOT_DEPLOY_HOOK")

    # Issue certificate
    local -a args=(certonly)
    case "$auth_mode" in
        webroot)    args+=(--webroot -w "$CB_CERTBOT_ONLY_WEBROOT") ;;
        standalone) args+=(--standalone) ;;
    esac
    args+=("${common_args[@]}")

    local primary="${VALID_DOMAINS[0]}"
    args+=(--cert-name "$primary")
    if (( ${#VALID_DOMAINS[@]} > 1 )); then
        args+=(--expand)
    fi
    local d
    for d in "${VALID_DOMAINS[@]}"; do
        args+=(-d "$d")
    done

    # Detect CA change / staging->production
    local live_cert="/etc/letsencrypt/live/$primary/fullchain.pem"
    if [[ -f "$live_cert" ]]; then
        local cur_issuer force_renew=0
        cur_issuer=$(openssl x509 -in "$live_cert" -noout -issuer 2>/dev/null || true)
        if [[ "$CB_STAGING" != "1" ]] && printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
            cb_warn "Existing cert is staging. Forcing --force-renewal."
            force_renew=1
        fi
        if [[ "$CB_STAGING" == "1" ]] && ! printf '%s' "$cur_issuer" | grep -qiE 'STAGING|FAKE'; then
            cb_warn "Existing cert is production, requesting staging. Forcing --force-renewal."
            force_renew=1
            args+=(--break-my-certs)
        fi
        if (( force_renew == 0 )); then
            local wanted_issuer_re=""
            case "$CB_CA" in
                letsencrypt) wanted_issuer_re='Let.?s Encrypt|STAGING|FAKE' ;;
                harica)      wanted_issuer_re='HARICA|Hellenic|GEANT|CESNET' ;;
                zerossl)     wanted_issuer_re='ZeroSSL' ;;
            esac
            if [[ -n "$wanted_issuer_re" && -n "$cur_issuer" ]] && ! printf '%s' "$cur_issuer" | grep -qiE "$wanted_issuer_re"; then
                cb_warn "Cert from a different CA (issuer: $cur_issuer). Forcing --force-renewal."
                force_renew=1
            fi
        fi
        (( force_renew )) && args+=(--force-renewal)
    fi

    cb_log "certbot $(cb_redact_eab "${args[@]}")"
    if ! cb_retry "${CB_RETRY_COUNT:-3}" "${CB_RETRY_DELAY:-10}" cb_certbot_issue "$primary" "${args[@]}"; then
        cb_die "certbot failed for: ${VALID_DOMAINS[*]}"
    fi
    cb_ok "Certificate issued: ${VALID_DOMAINS[*]}"
    cb_hook_set_cert "/etc/letsencrypt/live/$primary/fullchain.pem" \
                    "/etc/letsencrypt/live/$primary/privkey.pem" \
                    "$CB_CA" "certbot"
    export CA_SOURCE="certbot"
    _cb_only_run_hooks post-issue
}

stage_enable_timer() {
    if systemctl list-unit-files 2>/dev/null | grep '^certbot\.timer'; then >/dev/null
        systemctl enable --now certbot.timer >/dev/null 2>&1 && cb_ok "certbot.timer enabled"
    elif systemctl list-unit-files 2>/dev/null | grep '^snap.certbot.renew.timer'; then >/dev/null
        systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1 && cb_ok "snap certbot.renew.timer enabled"
    fi
}

# ============================================================================
on_failure() {
    local rc=$1
    [[ $rc -eq 0 ]] && return 0
    cb_error "Script failed (rc=$rc, stage=${CURRENT_STAGE:-?})"
    cb_rollback_hint
    export CA_PREV_EXIT="$rc" CA_PREV_STAGE="${CURRENT_STAGE:-?}"
    _cb_only_run_hooks on-failure 2>/dev/null || true
}
cb_on_exit_register on_failure
cb_setup_traps

run_stage() { CURRENT_STAGE="$1"; cb_debug "== stage: $1 =="; "stage_$1"; }

main() {
    parse_args "$@"
    run_stage prepare
    run_stage install_packages
    run_stage snapshot
    run_stage find_domains
    run_stage email
    run_stage install_deploy_hook
    run_stage issue_cert
    run_stage enable_timer
    cb_sep
    cb_ok "Done. Domains: ${VALID_DOMAINS[*]}"
    cb_log "Cert: /etc/letsencrypt/live/${VALID_DOMAINS[0]}/"
    cb_log ""
    cb_log "Important: certbot-only does NOT deploy the cert to any service."
    if [[ "${CB_ENABLE_HOOKS:-0}" == "1" ]]; then
        # Opt-in: certberus manages deployment via its own hook dirs + bridge.
        cb_log "Deployment is handled by your certberus hooks (--enable-hooks):"
        cb_log "  /etc/certberus/hooks/post-issue.d/   (on first issuance)"
        cb_log "  /etc/certberus/hooks/renewed.d/       (on each renewal, via the bridge)"
        if [[ -z "$(find "$CB_HOOKS_DIR/post-issue.d" "$CB_HOOKS_DIR/renewed.d" -maxdepth 1 -type f -executable 2>/dev/null | head -1)" ]]; then
            cb_warn "No hooks in post-issue.d/ or renewed.d/ - cert sits in /etc/letsencrypt/ without further action."
            cb_log "  Add an executable script to renewed.d/ (and post-issue.d/ for the first run);"
            cb_log "  it receives \$CA_CERT_PATH, \$CA_KEY_PATH, \$CA_PRIMARY_DOMAIN."
            cb_log "    certberus hooks list   # list hook dirs and bundled examples"
        fi
    else
        # Default: certbot owns renewal and deployment.
        cb_log "Deployment + renewal are certbot's job. Drop an executable script into:"
        cb_log "  /etc/letsencrypt/renewal-hooks/deploy/   (certbot runs it on issue and every renewal)"
        cb_log "  It receives \$RENEWED_LINEAGE and \$RENEWED_DOMAINS. Example:"
        cb_log "    install -m640 \"\$RENEWED_LINEAGE/fullchain.pem\" /etc/myservice/ && systemctl reload myservice"
        cb_log "  Or register one inline next time:  certberus ... --hook \"<command>\""
        cb_log "  Prefer certberus-managed hooks instead?  re-run with --enable-hooks"
        if [[ -n "$CB_CERTBOT_DEPLOY_HOOK" ]]; then
            cb_ok "Registered certbot --deploy-hook: $CB_CERTBOT_DEPLOY_HOOK"
        fi
    fi
    cb_mark_installed "certbot-only"
}
main "$@"
