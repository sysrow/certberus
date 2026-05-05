#!/bin/bash
# certberus/webservers/apache-md.sh
# Apache mod_md + Let's Encrypt (no EAB).
# Can be called standalone or via the `certberus` mother script.
#
# Usage:
#   apache-md.sh [-t|--staging] [-y|--yes] [-n|--dry-run] [-h|--help]
#                [--domain FOO] [--email EMAIL]
set -uo pipefail

# -------- Locate lib/ --------
_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
_LIB_DIR="${CB_LIB_DIR:-$(dirname "$_SCRIPT_DIR")/lib}"
if [[ ! -f "$_LIB_DIR/common.sh" ]]; then
    # fallback when installed to /usr/local
    for d in /usr/local/lib/certberus /usr/lib/certberus /opt/certberus/lib; do
        [[ -f "$d/common.sh" ]] && { _LIB_DIR="$d"; break; }
    done
fi
if [[ ! -f "$_LIB_DIR/common.sh" ]]; then
    echo "[ERR] Cannot find lib/common.sh. Set CB_LIB_DIR." >&2
    exit 2
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

cb_load_config  # loads config.env + advanced.env if they exist

# -------- Defaults specific to this module --------
: "${CB_APACHE_CONF_DIR:=/etc/apache2/sites-available}"
: "${CB_APACHE_ENABLED_DIR:=/etc/apache2/sites-enabled}"
: "${CB_MOD_MD_CONF:=/etc/apache2/conf-available/certberus-md.conf}"
: "${CB_MOD_MD_DIR:=/opt/certberus/mod_md}"
: "${CB_MOD_MD_HOOK_SCRIPT:=/opt/certberus/mod_md-adapter.sh}"
: "${CB_MOD_MD_LOG_DIR:=/var/log/mod_md}"
: "${CB_ACME_URL_LETSENCRYPT_PROD:=https://acme-v02.api.letsencrypt.org/directory}"
: "${CB_ACME_URL_LETSENCRYPT_STAGING:=https://acme-staging-v02.api.letsencrypt.org/directory}"

CB_EMAIL="${CB_EMAIL:-}"
CB_DOMAINS="${CB_DOMAINS:-}"
CB_CA="${CB_CA:-letsencrypt}"     # letsencrypt | harica | zerossl | custom
CB_EAB_KID="${CB_EAB_KID:-}"
CB_EAB_HMAC="${CB_EAB_HMAC:-}"
CB_ACME_URL="${CB_ACME_URL:-}"
CB_EAB_REQUIRED="${CB_EAB_REQUIRED:-0}"

APACHECTL=""
VALID_DOMAINS=()

# Per-process tempfile pro predani VALID_DOMAINS mezi stage funkcemi.
# Pouziva se mktemp -> nelze hijack predem-vytvorenym symlinkem.
CB_VALID_DOMAINS_FILE="$(mktemp -t certberus-domains.XXXXXX 2>/dev/null || echo "/tmp/certberus-domains.$$")"
trap 'rm -f "$CB_VALID_DOMAINS_FILE"' EXIT

usage() {
    cat <<USAGE
apache-md.sh - Apache mod_md + Let's Encrypt

Usage: $0 [OPTIONS]

  -t, --staging       Use staging CA (testing, no rate limits)
  -y, --yes           Non-interactive (Y to all)
  -n, --dry-run       Simulation without changes
  -v, --verbose       Debug output
      --domain D      Domain (repeatable)
      --email E       Contact email
      --ca NAME       letsencrypt | harica | zerossl
      --acme-url URL  Custom ACME directory URL
      --eab-kid KID   EAB key id (HARICA/ZeroSSL)
      --eab-hmac HMAC EAB HMAC key
      --no-firewall   Never automatically modify firewall
      --open-firewall Explicitly allow firewall mutations (including HARICA)
      --skip-dns-check Skip DNS A/AAAA -> server check (NAT/LB scenarios)
      --set CB_X=Y    Advanced override of any CB_* option
  -h, --help          This help

Configuration can also be set in /etc/certberus/config.env.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -t|--staging) CB_STAGING=1 ;;
            -y|--yes)     CB_ASSUME_YES=1 ;;
            -n|--dry-run) CB_DRY_RUN=1 ;;
            -v|--verbose) CB_VERBOSE=1 ;;
            --domain)     shift; CB_DOMAINS="${CB_DOMAINS} $1" ;;
            --email)      shift; CB_EMAIL="$1" ;;
            --ca)         shift; CB_CA="$1" ;;
            --acme-url)   shift; CB_ACME_URL="$1" ;;
            --eab-kid)    shift; CB_EAB_KID="$1" ;;
            --eab-hmac)   shift; CB_EAB_HMAC="$1" ;;
            --no-firewall) cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=0" ;;
            --open-firewall)
                cb_apply_cli_set "CB_FIREWALL_AUTO_OPEN=1"
                cb_apply_cli_set "CB_HARICA_FIREWALL_AUTO_OPEN=1"
                ;;
            --skip-dns-check) cb_apply_cli_set "CB_SKIP_DNS_CHECK=1" ;;
            --set) [[ $# -ge 2 ]] || cb_die "--set requires a value CB_NAME=value"; shift; cb_apply_cli_set "$1" ;;
            *) cb_warn "Unknown argument: $1" ;;
        esac
        shift
    done
}

# ============================================================================
# Stage functions
# ============================================================================

stage_prepare() {
    cb_banner "Certberus / Apache mod_md / Let's Encrypt"
    cb_log "OS: $CB_OS_ID $CB_OS_VERSION (pkg: $CB_PKG_MGR)"
    cb_log "Firewall: $(cb_firewall_backend_pretty)"
    cb_require_root
    cb_require_os debian ubuntu
    cb_hook_context apache ""

    # Directories
    mkdir -p "$CB_LOG_DIR" "$CB_MOD_MD_DIR" "$CB_MOD_MD_LOG_DIR" "$CB_STATE_DIR" 2>/dev/null
    chown root:www-data "$CB_MOD_MD_DIR" "$CB_MOD_MD_LOG_DIR" 2>/dev/null || true

    cb_run_hooks pre-install
}

stage_install_packages() {
    cb_sep
    local need=()
    cb_pkg_installed apache2 || need+=(apache2)
    # Minimum deps:
    #   - apache2  (webserver sam)
    #   - openssl  (self-signed fallback cert kdyz neni snakeoil)
    # NEINSTALUJEME:
    #   - iptables: respektujeme stav stroje. Kdyz je firewalld/ufw/nft, pouzijeme je.
    #     Kdyz neni vubec firewall (CB_FW_BACKEND=none), pouze varujeme - user
    #     rozhodne zda chce firewall pridat. Nikdy nezmenime backend na stroji.
    #   - apache2-utils: htpasswd/ab nepotrebujeme, apache2ctl je v apache2
    #   - ssl-cert: snakeoil fallback = openssl ad-hoc v CB_STATE_DIR
    #   - dnsutils: getent zvlada A/AAAA
    command -v openssl >/dev/null 2>&1 || need+=(openssl)

    if (( ${#need[@]} > 0 )); then
        cb_log "Missing packages: ${need[*]}"
        if cb_ask_yn "Install?" "Y/n"; then
            cb_pkg_install "${need[@]}" || cb_die "Installation failed"
        else
            cb_die "Cannot continue without packages ${need[*]}"
        fi
    else
        cb_ok "All packages are present"
    fi

    # Firewall - information only, no machine state mutation.
    case "$CB_FW_BACKEND" in
        none)
            cb_warn "No firewall detected on this machine (iptables/nft/ufw/firewalld)."
            cb_warn "Ports 80/443 must be accessible. Skipping all firewall operations."
            ;;
        firewalld|ufw|nftables|iptables-nft|iptables-legacy|docker)
            cb_log "Firewall: $(cb_firewall_backend_pretty)"
            ;;
    esac

    cb_run_hooks post-install
}

stage_check_apache_version() {
    local ver
    # Jedno awk misto dvou: F=/ vezme 2. pole a split() ho rozsekne na mezery.
    ver=$(apache2 -v 2>/dev/null | awk -F'/' '/version:/ {split($2,a," "); print a[1]; exit}')
    [[ -z "$ver" ]] && ver=$(apache2ctl -v 2>/dev/null | awk -F'/' '/version:/ {split($2,a," "); print a[1]; exit}')
    if [[ -z "$ver" ]]; then
        cb_warn "Cannot detect Apache version"
        return 0
    fi
    cb_log "Apache version: $ver"
    local a b c
    IFS=. read -r a b c <<<"$ver"
    if (( a*10000 + b*100 + ${c:-0} < 2*10000 + 4*100 + 34 )); then
        cb_die "Apache $ver je prilis stary. MDMessageCMD vyzaduje 2.4.34+ (Debian 10 dodava 2.4.38, Ubuntu 18.04 ma 2.4.29)."
    fi

    if command -v apache2ctl >/dev/null; then APACHECTL=apache2ctl
    elif command -v apachectl >/dev/null; then APACHECTL=apachectl
    else cb_die "Nenalezen apache2ctl/apachectl"
    fi
}

stage_snapshot() {
    cb_sep
    cb_run_hooks pre-snapshot
    cb_snapshot /etc/apache2 "apache2-pre-md" >/dev/null || cb_warn "Snapshot se nepodaril"
    cb_run_hooks post-snapshot
}

stage_preflight() {
    # Diagnostics of existing Apache state. Does not change anything.
    cb_preflight_apache || true  # rc is informational only
}

stage_fix_existing_ssl() {
    # If existing vhosts have SSLCertificateFile with a non-existent path,
    # replace with snakeoil (otherwise apache2ctl -t would fail).
    local fixed
    fixed=$(cb_apache_fix_ssl_cert_paths /etc/apache2)
    if (( fixed > 0 )); then
        cb_ok "Fixed $fixed vhosts with invalid SSL path"
    fi
}

stage_fix_broken_symlinks() {
    local broken
    broken=$(cb_apache_find_broken_symlinks /etc/apache2)
    if [[ -n "$broken" ]]; then
        cb_warn "Broken symlinks in Apache:"
        echo "$broken" | sed 's/^/    /'
        if cb_ask_yn "Remove broken symlinks?" "Y/n"; then
            [[ "$CB_DRY_RUN" == "0" ]] && echo "$broken" | xargs -r rm -f
            cb_ok "Broken symlinks removed"
        fi
    fi
}

# Auto-fix: regular files directly in sites-enabled/conf-enabled (Debian/Ubuntu quirk)
# Helps the admin instead of having to manually run mv + a2ensite.
stage_fix_sites_enabled_regular_files() {
    [[ -d /etc/apache2/sites-enabled || -d /etc/apache2/conf-enabled ]] || return 0
    # Najdi regular files (ne symlinky) - dry-run si jen dotazeme
    local found
    found=$(find /etc/apache2/sites-enabled /etc/apache2/conf-enabled \
        -maxdepth 1 -type f ! -name '*.bak_*' 2>/dev/null)
    [[ -z "$found" ]] && return 0

    cb_warn "Found regular files directly in sites-enabled/conf-enabled:"
    echo "$found" | sed 's/^/    /'
    cb_log "Debian/Ubuntu Apache expects only symlinks here. a2dissite does not work for the admin this way."
    if cb_ask_yn "Move to sites-available/conf-available and create symlinks?" "Y/n"; then
        local fixed
        fixed=$(cb_apache_fix_sites_enabled_regular_files /etc/apache2)
        if (( fixed > 0 )); then
            cb_ok "Moved $fixed files (backups .bak_* remain)"
        fi
    fi
}

# Detect other active MDomain conf - prevents AH10038 "overlap"
# Covers: apache2.conf, conf-available/enabled, sites-*, mods-*, conf.d, unknown locations.
stage_detect_existing_md() {
    cb_sep
    local my_name; my_name=$(basename "$CB_MOD_MD_CONF" .conf)
    local sources kept=0

    sources=$(cb_apache_md_sources 2>/dev/null || true)
    if [[ -z "$sources" ]]; then
        cb_ok "No conflicting MDomain configuration found"
        return 0
    fi

    # Filtering: skip files that belong to our config
    local cat path enabled
    local -a dangerous=()
    while IFS=$'\t' read -r cat path enabled; do
        [[ -z "$path" ]] && continue
        # Our own file
        [[ "$(basename "$path" .conf)" == "$my_name" ]] && continue
        # .bak/.disabled etc. are fine
        [[ "$cat" == "disabled" ]] && continue
        dangerous+=("$cat|$path|$enabled")
    done <<< "$sources"

    if (( ${#dangerous[@]} == 0 )); then
        cb_ok "No conflicting MDomain configuration found (only bak/disabled)"
        return 0
    fi

    cb_warn "Found ${#dangerous[@]} locations with MDomain:"
    local item
    for item in "${dangerous[@]}"; do
        IFS='|' read -r cat path enabled <<< "$item"
        printf '    [%-16s enabled=%s] %s\n' "$cat" "$enabled" "$path"
    done

    if ! cb_ask_yn "Automatically deactivate/comment out all these locations?" "Y/n"; then
        cb_die "Without deactivation there will be an MDomain collision (AH10038 or duplication)"
    fi

    for item in "${dangerous[@]}"; do
        IFS='|' read -r cat path enabled <<< "$item"
        cb_apache_disable_md_source "$cat" "$path" || cb_warn "Cannot deactivate: $path"
    done
    cb_ok "Conflicting MDomain entries deactivated"
}

stage_cleanup_staging_data() {
    local MD_BASE="/etc/apache2/md"
    [[ -d "$MD_BASE" ]] || return 0
    if [[ "$CB_STAGING" == "1" ]]; then
        cb_debug "Staging mode active, keeping data"
        return 0
    fi
    cb_sep
    if grep -Riq "acme-staging" "$MD_BASE/domains" 2>/dev/null; then
        cb_warn "Found staging data in $MD_BASE/domains - deleting"
        [[ "$CB_DRY_RUN" == "0" ]] && rm -rf "$MD_BASE/domains"/* "$MD_BASE/tmp"/* "$MD_BASE/archive"/* 2>/dev/null
        cb_ok "Staging data cleaned"
    fi
}

get_enabled_sites() {
    find "$CB_APACHE_ENABLED_DIR" -type l -exec readlink -f {} + 2>/dev/null | \
        grep "$CB_APACHE_CONF_DIR" | sort -u
}

stage_find_domains() {
    cb_sep

    # If admin provided domains via flags/config, we don't browse vhosts
    if [[ -n "$CB_DOMAINS" ]]; then
        for d in $CB_DOMAINS; do
            cb_validate_domain "$d" || { cb_warn "Ignoring invalid domain: $d"; continue; }
            # I pri explicitnim zadani aspon varujme, kdyz DNS nemiri sem.
            # Nezastavujeme se - admin to mohl predat zamerne (split-DNS, NAT).
            if [[ "$d" != \** ]] && ! cb_domain_points_here "$d"; then
                cb_warn "DNS A/AAAA for $d does not point to this server - HTTP-01 challenge may fail."
                cb_warn "  (Continuing - if behind NAT/LB, use --skip-dns-check to suppress this warning.)"
            fi
            VALID_DOMAINS+=("$d")
        done
        if (( ${#VALID_DOMAINS[@]} == 0 )); then
            cb_die "No valid domain in CB_DOMAINS"
        fi
        cb_log "Domains from configuration: ${VALID_DOMAINS[*]}"
        printf "%s\n" "${VALID_DOMAINS[@]}" > "$CB_VALID_DOMAINS_FILE"
        return 0
    fi

    # Otherwise auto-detect from vhosts
    if [[ -z "$(ls -A "$CB_APACHE_ENABLED_DIR" 2>/dev/null)" ]]; then
        cb_die "V $CB_APACHE_ENABLED_DIR nejsou aktivovane stranky (a2ensite NAME)"
    fi

    cb_log "Searching for domains in $CB_APACHE_ENABLED_DIR"
    local ENABLED_SITES DOMAIN_LIST HOSTNAME_FQ UNIQUE_DOMAINS
    ENABLED_SITES=$(get_enabled_sites)
    DOMAIN_LIST=$(grep -hE '^\s*Server(Name|Alias)\s+' $ENABLED_SITES 2>/dev/null | \
        awk '{for(i=2;i<=NF;i++) print $i}')
    HOSTNAME_FQ=$(hostname -f 2>/dev/null)
    [[ "$HOSTNAME_FQ" == *.* ]] && DOMAIN_LIST="$DOMAIN_LIST"$'\n'"$HOSTNAME_FQ"
    UNIQUE_DOMAINS=$(echo "$DOMAIN_LIST" | grep -E '^[a-zA-Z0-9.*-]+$' | sort -u)

    local d
    for d in $UNIQUE_DOMAINS; do
        if [[ "$d" == \** ]]; then
            cb_log "[SKIP] Wildcard $d (not supported by HTTP-01)"
            continue
        fi
        if ! cb_validate_domain "$d"; then
            cb_debug "Invalid domain: $d"
            continue
        fi
        if cb_domain_points_here "$d"; then
            VALID_DOMAINS+=("$d")
            cb_ok "Domain OK: $d"
        else
            cb_warn "Domain does not point to this server: $d"
        fi
    done

    if (( ${#VALID_DOMAINS[@]} == 0 )); then
        cb_die "No valid domain found"
    fi
    printf "%s\n" "${VALID_DOMAINS[@]}" > "$CB_VALID_DOMAINS_FILE"
    cb_ok "Valid domains: ${VALID_DOMAINS[*]}"
    cb_hook_context apache "${VALID_DOMAINS[@]}"
}

stage_enable_modules() {
    cb_sep
    local mods m
    mods=$("$APACHECTL" -M 2>&1)
    for m in md ssl; do
        if echo "$mods" | grep -q "${m}_module"; then
            cb_debug "Module '$m' active"
        else
            cb_log "Enabling module '$m'"
            [[ "$CB_DRY_RUN" == "0" ]] && a2enmod "$m" >/dev/null 2>&1
        fi
    done
    # Po a2enmod overit ze modul je doopravdy nactitelny (apache2ctl -M
    # nacita celou config, takze pokud chybi knihovny / jine konflikty,
    # uvidime tady; lepsi nez chyba pri reloadu po nakonfigurovani MDomain).
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        local check; check=$("$APACHECTL" -M 2>&1)
        if ! echo "$check" | grep -q 'md_module'; then
            cb_error "mod_md neni nactitelny po a2enmod md."
            cb_log "  Mozne priciny:"
            cb_log "    - balicek libapache2-mod-md neni instalovan (apt install libapache2-mod-md)"
            cb_log "    - Apache <2.4.34 (Ubuntu 18.04: upgrade na bionic-backports)"
            cb_log "    - jiny modul drzi konflikt s mod_md (apache2ctl -M | grep md)"
            cb_log "  Restart bez mod_md:  a2dismod md && systemctl reload apache2"
            cb_die "mod_md unavailable"
        fi
        if ! echo "$check" | grep -q 'ssl_module'; then
            cb_error "mod_ssl neni nactitelny po a2enmod ssl."
            cb_log "  Resime:  apt install --reinstall apache2-bin"
            cb_die "mod_ssl unavailable"
        fi
    fi
}

stage_generate_config() {
    cb_sep
    readarray -t VALID_DOMAINS < "$CB_VALID_DOMAINS_FILE"
    local domains_line; domains_line=$(printf "%s " "${VALID_DOMAINS[@]}")

    # Email - from config, CLI, or ServerAdmin
    local email="$CB_EMAIL"
    if [[ -z "$email" ]]; then
        local ENABLED_SITES emails
        ENABLED_SITES=$(get_enabled_sites)
        emails=$(grep -hE '^\s*ServerAdmin\s+' $ENABLED_SITES 2>/dev/null | \
            awk '{print $2}' | sort -u | grep -v 'localhost$' || true)
        for e in $emails; do
            if cb_validate_email "$e"; then email="$e"; break; fi
        done
    fi
    if [[ -z "$email" ]]; then
        email=$(cb_ask_in "Contact email for LE" "${CB_EMAIL:-admin@$(hostname -d 2>/dev/null || echo example.com)}")
    fi
    cb_validate_email "$email" || cb_die "Invalid email: $email"
    CB_EMAIL="$email"

    # Choose CA and URL
    local ca_url="$CB_ACME_URL"
    if [[ -z "$ca_url" ]]; then
        case "$CB_CA" in
            letsencrypt)
                if [[ "$CB_STAGING" == "1" ]]; then
                    ca_url="$CB_ACME_URL_LETSENCRYPT_STAGING"
                    cb_warn "STAGING mode - issued certs are not trusted"
                fi
                ;;
            harica)
                ca_url="${CB_ACME_URL_HARICA:-}"
                CB_EAB_REQUIRED=1
                [[ -n "$ca_url" ]] || cb_die "CA harica requires per-account --acme-url/CB_ACME_URL_HARICA and EAB KID/HMAC (e.g. https://acme.harica.gr/<alias>/directory)."
                [[ "$ca_url" != *".../"* && "$ca_url" != *"VAS_"* && "$ca_url" != *"<"* ]] || cb_die "HARICA ACME URL looks like a placeholder: $ca_url"
                ;;
            zerossl)
                ca_url="${CB_ACME_URL_ZEROSSL:-https://acme.zerossl.com/v2/DV90}"
                CB_EAB_REQUIRED=1
                ;;
        esac
    fi

    # EAB check
    if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
        [[ -n "$CB_EAB_KID" ]] || CB_EAB_KID=$(cb_ask_in "EAB KID" "")
        [[ -n "$CB_EAB_HMAC" ]] || CB_EAB_HMAC=$(cb_ask_secret "EAB HMAC")
        [[ -n "$CB_EAB_KID" && -n "$CB_EAB_HMAC" ]] || \
            cb_die "CA $CB_CA requires EAB KID and HMAC"
    fi

    cb_log "Generating $CB_MOD_MD_CONF (CA=$CB_CA)"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        {
            echo "# Generated by certberus / apache-md.sh / $(date)"
            echo "# CA: $CB_CA"
            echo "MDCertificateAgreement accepted"
            echo "MDomain $domains_line"
            echo "MDContactEmail $email"
            echo "MDMembers manual"
            echo "MDMessageCMD $CB_MOD_MD_HOOK_SCRIPT"
            [[ -n "$ca_url" ]] && echo "MDCertificateAuthority $ca_url"
            if [[ "$CB_EAB_REQUIRED" == "1" ]]; then
                echo "MDExternalAccountBinding $CB_EAB_KID $CB_EAB_HMAC"
            fi
        } > "$CB_MOD_MD_CONF"
        chmod 640 "$CB_MOD_MD_CONF"
        chown root:www-data "$CB_MOD_MD_CONF" 2>/dev/null || true
    fi
    cb_ok "Configuration: $CB_MOD_MD_CONF"
}

stage_install_hook_adapter() {
    cb_sep
    cb_log "Installing MDMessageCMD adapter -> $CB_MOD_MD_HOOK_SCRIPT"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        local hook_dir; hook_dir="$(dirname "$CB_MOD_MD_HOOK_SCRIPT")"
        mkdir -p "$hook_dir"
        # /opt/certberus and parent must be traversable by www-data;
        # otherwise Apache (running as www-data) cannot call MDMessageCMD
        # and mod_md reports 'failed with exit code 255' = permission denied.
        chmod 0755 "$hook_dir" 2>/dev/null || true
        cb_mod_md_adapter_body > "$CB_MOD_MD_HOOK_SCRIPT"
        # 0750 + group www-data = root can edit, www-data can read+exec
        chmod 0750 "$CB_MOD_MD_HOOK_SCRIPT"
        chown root:www-data "$CB_MOD_MD_HOOK_SCRIPT" 2>/dev/null || true
        # CB_MOD_MD_DIR (mod_md store) stays 0700 root:root - Apache
        # does not need it, mod_md writes paths via a different mechanism.
    fi
    cb_ok "Hook adapter OK"
}

stage_sudoers() {
    local SUDOERS_FILE="/etc/sudoers.d/certberus_mod_md"
    local IPT APCH tmp
    APCH=$(command -v apache2ctl || echo /usr/sbin/apache2ctl)
    [[ -x "$APCH" ]] || cb_die "apache2ctl nenalezen"

    # Sudoers for port 80 ACCEPT dropdown only makes sense when the backend is iptables*.
    # For firewalld/ufw/nft the hook adapter uses firewall-cmd/ufw/nft (see hooks).
    # For 'none' backend no firewall mutation - sudoers for graceful only.
    local need_ipt=0
    case "$CB_FW_BACKEND" in
        iptables-nft|iptables-legacy)
            IPT=$(command -v iptables || echo /usr/sbin/iptables)
            [[ -x "$IPT" ]] && need_ipt=1
            ;;
    esac

    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] sudoers -> $SUDOERS_FILE"
        return 0
    fi
    tmp=$(mktemp)
    {
        echo "# Certberus - rules for mod_md hook adapter"
        if (( need_ipt )); then
            cat <<EOF
www-data ALL=(ALL) NOPASSWD: $IPT -A INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment *
www-data ALL=(ALL) NOPASSWD: $IPT -D INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment *
www-data ALL=(ALL) NOPASSWD: $IPT -C INPUT -p tcp --dport 80 -j ACCEPT -m comment --comment *
EOF
        fi
        echo "www-data ALL=(ALL) NOPASSWD: $APCH graceful"
    } > "$tmp"
    if visudo -cf "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"; chown root:root "$SUDOERS_FILE"
        cb_ok "Sudoers: $SUDOERS_FILE"
    else
        rm -f "$tmp"
        cb_die "Sudoers syntax error"
    fi
}

stage_enable_config() {
    cb_sep
    local name; name=$(basename "$CB_MOD_MD_CONF" .conf)
    cb_log "Enabling conf '$name'"
    [[ "$CB_DRY_RUN" == "0" ]] && a2enconf "$name" >/dev/null 2>&1
}

stage_fix_ssl_vhosts() {
    cb_sep
    cb_log "Checking SSL configuration in vhosts"
    readarray -t VALID_DOMAINS < "$CB_VALID_DOMAINS_FILE"
    local ENABLED_SITES ts f CONFIG_DOMAINS found_valid
    ENABLED_SITES=$(get_enabled_sites)
    ts=$(date +%F_%T)

    for f in $ENABLED_SITES; do
        [[ -s "$f" ]] || continue
        CONFIG_DOMAINS=$(grep -E "^\s*(ServerName|ServerAlias)\s+" "$f" 2>/dev/null | \
            awk '{for(i=2;i<=NF;i++) print $i}' | sort -u)
        found_valid=0
        for d in $CONFIG_DOMAINS; do
            for v in "${VALID_DOMAINS[@]}"; do
                [[ "$d" == "$v" ]] && { found_valid=1; break 2; }
            done
        done
        (( found_valid )) || continue

        if ! grep -qE '^[^#]*<VirtualHost [^>]*:443>' "$f"; then continue; fi

        local backed=0
        if ! grep -qE '^[[:space:]]*SSLEngine\s+on\b' "$f"; then
            (( backed )) || { cp "$f" "$f.bak_$ts"; backed=1; }
            [[ "$CB_DRY_RUN" == "0" ]] && \
                sed -i '/^[^#]*<VirtualHost [^>]*:443>/ a \    SSLEngine on' "$f"
            cb_log "+ SSLEngine on -> $f"
        fi
        if ! grep -qE '^\s*SSLCertificate(File|KeyFile)\b' "$f"; then
            # Find a usable cert: snakeoil or our fallback
            local cf="" kf=""
            if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem && -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
                cf=/etc/ssl/certs/ssl-cert-snakeoil.pem
                kf=/etc/ssl/private/ssl-cert-snakeoil.key
            elif [[ -f "$CB_STATE_DIR/fallback-cert.pem" && -f "$CB_STATE_DIR/fallback-key.pem" ]]; then
                cf="$CB_STATE_DIR/fallback-cert.pem"
                kf="$CB_STATE_DIR/fallback-key.pem"
            fi
            if [[ -n "$cf" ]]; then
                (( backed )) || { cp "$f" "$f.bak_$ts"; backed=1; }
                [[ "$CB_DRY_RUN" == "0" ]] && \
                    sed -i "/^[^#]*<VirtualHost [^>]*:443>/ a \\    SSLCertificateFile    $cf\\n    SSLCertificateKeyFile $kf" "$f"
                cb_log "+ self-signed fallback -> $f (mod_md will overwrite after issuance)"
            fi
        fi
    done
}

stage_firewall() {
    if cb_firewall_acme_auto_open_enabled; then
        cb_firewall_snapshot >/dev/null
        cb_firewall_ensure_http_https
    else
        cb_debug "Firewall auto-open skipped"
    fi
}

# If no enabled :443 vhost has a ServerName / ServerAlias matching
# our primary domain, mod_md will issue the cert into its store but Apache
# will never load it because there is no vhost to pick it up.
# We create a stub /etc/apache2/sites-available/certberus-ssl-<dom>.conf with
# a minimal SSL vhost (snakeoil/fallback cert -> mod_md overwrites on
# graceful) and a2ensite. The key is 'ServerName' = matches MDomain.
stage_ensure_ssl_vhost() {
    cb_sep
    cb_log "Checking for :443 vhosts matching our domains"
    readarray -t VALID_DOMAINS < "$CB_VALID_DOMAINS_FILE"
    local primary="${VALID_DOMAINS[0]:-}"
    [[ -z "$primary" ]] && { cb_warn "No primary domain - skipping"; return 0; }

    local ENABLED_SITES f
    ENABLED_SITES=$(get_enabled_sites)
    local found_443_match=0

    # Look for a :443 vhost with ServerName/Alias equal to at least one of our domains.
    for f in $ENABLED_SITES; do
        [[ -s "$f" ]] || continue
        # Simple single-vhost parser sufficient for detection - 99% of Debian deployments.
        if grep -qE '^[^#]*<VirtualHost [^>]*:443>' "$f"; then
            local cfg_doms
            cfg_doms=$(grep -E "^\s*(ServerName|ServerAlias)\s+" "$f" 2>/dev/null \
                | awk '{for(i=2;i<=NF;i++) print $i}')
            for d in $cfg_doms; do
                for v in "${VALID_DOMAINS[@]}"; do
                    [[ "$d" == "$v" ]] && { found_443_match=1; break 3; }
                done
            done
        fi
    done

    if (( found_443_match )); then
        cb_ok ":443 vhost with matching ServerName found"
        return 0
    fi

    cb_warn "No :443 vhost matches '$primary' - generating stub"

    # Find a fallback cert for initial start (without it apache2 -t fails).
    # mod_md will overwrite it with the correct cert file after graceful.
    local cf="" kf=""
    if [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem && -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
        cf=/etc/ssl/certs/ssl-cert-snakeoil.pem
        kf=/etc/ssl/private/ssl-cert-snakeoil.key
    elif [[ -f "$CB_STATE_DIR/fallback-cert.pem" && -f "$CB_STATE_DIR/fallback-key.pem" ]]; then
        cf="$CB_STATE_DIR/fallback-cert.pem"
        kf="$CB_STATE_DIR/fallback-key.pem"
    else
        # Without snakeoil we try make-ssl-cert or generate a self-signed cert.
        if command -v make-ssl-cert >/dev/null 2>&1 && [[ "$CB_DRY_RUN" == "0" ]]; then
            make-ssl-cert generate-default-snakeoil --force-overwrite >/dev/null 2>&1 || true
            [[ -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]] && {
                cf=/etc/ssl/certs/ssl-cert-snakeoil.pem
                kf=/etc/ssl/private/ssl-cert-snakeoil.key
            }
        fi
        if [[ -z "$cf" ]] && [[ "$CB_DRY_RUN" == "0" ]]; then
            mkdir -p "$CB_STATE_DIR"
            cf="$CB_STATE_DIR/fallback-cert.pem"
            kf="$CB_STATE_DIR/fallback-key.pem"
            openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
                -subj "/CN=$primary/O=certberus-fallback" \
                -keyout "$kf" -out "$cf" >/dev/null 2>&1 \
                || { cb_warn "Nemohu vyrobit fallback cert"; return 0; }
            chmod 0640 "$kf" 2>/dev/null
            cb_log "Generated self-signed fallback: $cf"
        fi
    fi

    # Stub vhost: SSL on, fallback cert (mod_md will overwrite), ServerName + ServerAlias
    # for all our domains so that SNI and MDomain match.
    local stub_conf="$CB_APACHE_CONF_DIR/certberus-ssl.conf"
    local stub_name="certberus-ssl"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        local tmp; tmp=$(mktemp)
        {
            echo "# Auto-generated by certberus. mod_md will overwrite SSLCertificate* after issuance."
            echo "# Safe to delete if you have your own :443 vhost with ServerName=$primary."
            echo "<VirtualHost *:443>"
            echo "    ServerName $primary"
            local i
            for (( i=1; i<${#VALID_DOMAINS[@]}; i++ )); do
                echo "    ServerAlias ${VALID_DOMAINS[$i]}"
            done
            echo "    DocumentRoot /var/www/html"
            echo "    SSLEngine on"
            if [[ -n "$cf" ]]; then
                echo "    SSLCertificateFile    $cf"
                echo "    SSLCertificateKeyFile $kf"
            fi
            echo "</VirtualHost>"
        } > "$tmp"
        # Backup any existing conf file before overwriting
        if [[ -f "$stub_conf" ]]; then
            cp "$stub_conf" "$stub_conf.bak_$(date +%F_%T)"
        fi
        mv "$tmp" "$stub_conf"
        chmod 0644 "$stub_conf"
        a2ensite "$stub_name" >/dev/null 2>&1
        cb_ok "Stub :443 vhost: $stub_conf"
    else
        cb_log "[DRY-RUN] Would create $stub_conf with ServerName=$primary"
    fi
}

stage_test_reload() {
    cb_sep
    cb_run_hooks pre-reload

    cb_log "Testing syntax (apache2ctl -t)"
    if ! "$APACHECTL" -t 2>&1 | tee -a "$CB_LOG_FILE"; then
        cb_error "Syntax error in Apache config AFTER our changes"
        if [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]]; then
            cb_snapshot_restore "$CB_LAST_SNAPSHOT"
        else
            cb_rollback_hint
        fi
        cb_die "Aborting without reload (Apache remains in original state)"
    fi

    if ! cb_svc_is_active apache2; then
        cb_warn "Apache is not running - attempting start"
        if [[ "$CB_DRY_RUN" == "0" ]] && ! cb_svc_start apache2; then
            # Start selhal - zkusime rollback a znovu
            if [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]]; then
                cb_error "Apache start failed - attempting rollback and retry"
                cb_snapshot_restore "$CB_LAST_SNAPSHOT"
                cb_svc_start apache2 || cb_die "Apache se nepodarilo nastartovat ani po rollbacku"
                cb_die "Apache start po rollbacku OK, ale konfigurace se nenasadila"
            else
                cb_rollback_hint
                cb_die "Apache start failed"
            fi
        fi
    fi

    cb_log "Reload Apache"
    if [[ "$CB_DRY_RUN" == "0" ]]; then
        if ! cb_svc_reload apache2; then
            cb_error "Reload failed"
            if [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]]; then
                cb_snapshot_restore "$CB_LAST_SNAPSHOT"
                cb_svc_reload apache2 || cb_svc_restart apache2 || cb_die "Apache neni opravitelny"
                cb_die "Rollback hotov, puvodni stav zachovan"
            fi
            cb_svc_restart apache2 || cb_die "Apache restart selhal"
        fi
    fi
    cb_ok "Apache OK"
    cb_mark_installed "apache-md"
    cb_run_hooks post-reload
}

# After reload, Apache mod_md starts ASYNCHRONOUSLY negotiating with the ACME server.
# The cert typically arrives in 10-60s and is stored in /etc/apache2/md/domains/<dom>/.
# For Apache to load the cert into live SSL state, ONE MORE graceful is needed
# (otherwise the cert sits in the store unused). The MDMessageCmd adapter does this
# automatically on the 'installed' event, BUT:
#   - mod_md emits 'installed' only when the cert transitions from 'staging' to 'domains',
#     which does not happen if the cert is already there from a previous run (state=2)
#   - if the adapter crashed with exit 255 in a previous version (perm bug), the event
#     passed without action and Apache never got the graceful -> cert in store, service
#     ignores it
#
# This stage therefore ACTIVELY polls the store, and when it finds a pubcert.pem that
# Apache has not yet loaded, it forces a graceful itself. Idempotent - if Apache already
# serves the LE cert, we just confirm and exit.
#
# Vypnutelne pres CB_POST_ISSUE_WAIT=0 (default 1).
# Timeout pres CB_POST_ISSUE_TIMEOUT (default 120 sekund).
stage_post_issue_activate() {
    [[ "${CB_POST_ISSUE_WAIT:-1}" == "1" ]] || { cb_debug "post_issue_activate disabled"; return 0; }
    [[ "$CB_DRY_RUN" == "1" ]] && return 0
    cb_sep
    readarray -t VALID_DOMAINS < "$CB_VALID_DOMAINS_FILE"
    local primary="${VALID_DOMAINS[0]:-}"
    [[ -z "$primary" ]] && return 0

    # mod_md ma DVA store dirs:
    #   /etc/apache2/md/staging/<dom>/  - cert ktery prave dorazil z ACME, ale
    #                                     Apache ho jeste nenacetl. Tady se
    #                                     objevi pubcert.pem hned po vystaveni.
    #   /etc/apache2/md/domains/<dom>/  - cert ktery JE live (Apache ho servuje).
    #                                     Sem se cert presune az pri 'graceful'.
    #
    # mod_md NEemituje zadny MDMessageCmd event mezi 'cert v staging' a
    # 'admin udelal graceful'. Logovani je AH10059 'will be activated on next
    # graceful server restart' - to je vsechno. Takze post_issue_activate
    # POLL-uje staging, a kdyz tam najde cert, sam donuti graceful, coz spusti
    # presun do domains a 'installed' event pro adapter.
    local md_root="${CB_MOD_MD_APACHE_STORE_ROOT:-/etc/apache2/md}"
    local staging_cert="$md_root/staging/$primary/pubcert.pem"
    local domains_cert="$md_root/domains/$primary/pubcert.pem"
    local timeout="${CB_POST_ISSUE_TIMEOUT:-120}"

    cb_log "Cekam na vystaveni certifikatu (max ${timeout}s, mod_md staging=$md_root/staging)"

    local waited=0 step=3 ready=0
    while (( waited < timeout )); do
        # Cert uz je v domains (z minuleho behu) -> hotovo, jen overime serving.
        if [[ -s "$domains_cert" ]]; then
            ready=2
            break
        fi
        # Cert je v staging -> potrebujeme graceful
        if [[ -s "$staging_cert" ]]; then
            ready=1
            break
        fi
        sleep "$step"
        waited=$(( waited + step ))
    done

    if (( ready == 0 )); then
        cb_warn "Cert v $md_root/{staging,domains}/$primary/pubcert.pem nedorazil za ${timeout}s"
        cb_log "  mod_md mozna stale jedna s CA. Sleduj:"
        cb_log "    tail -f /var/log/apache2/error.log | grep -i 'md\\['"
        cb_log "  Az dorazi, spust: $APACHECTL graceful"
        return 0
    fi

    if (( ready == 1 )); then
        cb_ok "Cert v staging: $staging_cert"
        cb_log "Force graceful Apache (presun staging -> domains, aktivace certu)"
        if "$APACHECTL" graceful >>"$CB_LOG_FILE" 2>&1; then
            cb_ok "graceful OK"
        else
            cb_warn "graceful selhal - zkus rucne: $APACHECTL graceful"
            return 0
        fi
        # Pockame chvili nez mod_md presun dokonci
        local s=0
        while (( s < 15 )); do
            [[ -s "$domains_cert" ]] && break
            sleep 1; s=$((s+1))
        done
    else
        cb_ok "Cert uz je v domains: $domains_cert (z minuleho behu)"
        # I tak udelame graceful, kdyby Apache mel cached starou verzi
        "$APACHECTL" graceful >>"$CB_LOG_FILE" 2>&1 || true
    fi

    if [[ ! -s "$domains_cert" ]]; then
        cb_warn "Cert se NEpresunul do $domains_cert ani po graceful"
        return 0
    fi

    # Zjisti issuer & expiry pro vypis
    local issuer notafter
    issuer=$(timeout 3 openssl x509 -in "$domains_cert" -noout -issuer </dev/null 2>/dev/null | sed 's/^issuer=//')
    notafter=$(timeout 3 openssl x509 -in "$domains_cert" -noout -enddate </dev/null 2>/dev/null | sed 's/^notAfter=//')
    [[ -n "$issuer"   ]] && cb_log "  issuer:  $issuer"
    [[ -n "$notafter" ]] && cb_log "  expires: $notafter"

    # Sanity check: openssl s_client proti :443 musi vratit issuer ktery NENI
    # snakeoil/fallback. Pokud LE cert se neaktivoval, je to user-actionable.
    sleep 2
    local served_issuer
    served_issuer=$(echo | timeout 5 openssl s_client \
        -servername "$primary" -connect "127.0.0.1:443" </dev/null 2>/dev/null \
        | timeout 3 openssl x509 -noout -issuer 2>/dev/null \
        | sed 's/^issuer=//')
    if [[ -z "$served_issuer" ]]; then
        cb_warn ":443 nereaguje - mozna chybi Listen 443 nebo apache2 nenastartoval"
        return 0
    fi

    case "$served_issuer" in
        *snakeoil*|*certberus-fallback*)
            cb_warn ":443 stale servuje fallback ($served_issuer)"
            cb_warn "  Apache cert nenahral. Zkus: $APACHECTL -t && $APACHECTL graceful"
            cb_warn "  Nebo zkontroluj ze ServerName v :443 vhostu = $primary"
            ;;
        *)
            cb_ok ":443 servuje cert: $served_issuer"
            ;;
    esac
}

# ============================================================================
# Main
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

run_stage() {
    CURRENT_STAGE="$1"
    cb_debug "== stage: $1 =="
    "stage_$1"
}

main() {
    parse_args "$@"
    run_stage prepare
    run_stage install_packages
    run_stage check_apache_version
    run_stage preflight
    run_stage snapshot
    run_stage fix_broken_symlinks
    run_stage fix_sites_enabled_regular_files
    run_stage fix_existing_ssl
    run_stage detect_existing_md
    run_stage cleanup_staging_data
    run_stage find_domains
    cb_run_hooks pre-issue
    run_stage enable_modules
    run_stage generate_config
    run_stage install_hook_adapter
    run_stage sudoers
    run_stage enable_config
    run_stage fix_ssl_vhosts
    run_stage ensure_ssl_vhost
    run_stage firewall
    run_stage test_reload
    run_stage post_issue_activate
    cb_run_hooks post-issue
    cb_sep
    cb_ok "Done. Domains: ${VALID_DOMAINS[*]}"
    cb_log "Log: $CB_LOG_FILE"
    [[ "$CB_STAGING" == "1" ]] && cb_warn "STAGING mode - cert is not trusted in browsers"

    # Next steps: mod_md obtains the certificate ASYNCHRONOUSLY AFTER Apache reload.
    # First issuance typically takes 10-60s, sometimes several minutes.
    cb_sep
    local _first="${VALID_DOMAINS[0]}"
    cb_log "Next steps (mod_md requests cert ASYNCHRONOUSLY - typically 10-60s):"
    cb_log ""
    cb_log "  Wait a few seconds then:"
    cb_log "    certberus cert-info ${_first}"
    cb_log ""
    cb_log "  Watch progress:"
    cb_log "    tail -f /var/log/apache2/error.log | grep -i 'md\\['"
    cb_log ""
    cb_log "  If cert does not arrive within 5 minutes:"
    cb_log "    certberus test-domain ${_first}     # checks DNS, CAA, port 80"
}

main "$@"
