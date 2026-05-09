#!/bin/bash
# certberus/lib/preflight.sh
# Pre-flight checks and auto-fix of broken states:
#  - stale MDomain configurations in various locations
#  - non-functional SSLCertificateFile paths
#  - broken symlinks in sites-enabled
#  - syntax in apache2.conf
#
# API:
#   cb_preflight_apache   -> stdout: report, exit 0 OK, 1 fixable, 2 fatal
#   cb_preflight_nginx
#   cb_preflight_tomcat
#   cb_apache_md_sources  -> stdout: files with MDomain with category
#   cb_apache_fix_ssl_cert_paths -> replaces non-existent SSLCertificate* with snakeoil

[[ -n "${_CB_PREFLIGHT_LOADED:-}" ]] && return 0
_CB_PREFLIGHT_LOADED=1

# Apache requires a non-empty regular readable file with cert/key.
# Returns 0 if the path is invalid (= needs fix), 1 if OK/not specified.
_cb_ssl_path_invalid() {
    local p="$1"
    [[ -z "$p" ]] && return 1           # empty = not specified, ignore
    [[ ! -e "$p" ]] && return 0         # does not exist
    [[ -d "$p" ]] && return 0           # directory
    [[ ! -f "$p" ]] && return 0         # not a regular file
    [[ ! -s "$p" ]] && return 0         # empty
    [[ ! -r "$p" ]] && return 0         # unreadable
    return 1
}

# -------- Apache: where MDomain can reside --------
# Scans /etc/apache2/* and categorizes.
# Output: "CATEGORY\tPATH\tENABLED" for each match.
# CATEGORY: conf-enabled|conf-available|apache2.conf|mods-*|sites-*|disabled|unknown
cb_apache_md_sources() {
    local roots=()
    for d in /etc/apache2 /etc/httpd; do
        [[ -d "$d" ]] && roots+=("$d")
    done
    (( ${#roots[@]} == 0 )) && return 0

    local f cat enabled
    while IFS= read -r -d '' f; do
        # Skip binary/unreadable
        [[ -r "$f" ]] || continue

        # Filename - skip .bak, .disabled, .example, tilde-suffix
        case "$f" in
            *.bak|*.bak_*|*.disabled|*.example|*.orig|*~) cat="disabled" ;;
            */apache2.conf|*/httpd.conf) cat="master" ;;
            */conf-enabled/*) cat="conf-enabled" ;;
            */conf-available/*) cat="conf-available" ;;
            */sites-enabled/*) cat="sites-enabled" ;;
            */sites-available/*) cat="sites-available" ;;
            */mods-enabled/*) cat="mods-enabled" ;;
            */mods-available/*) cat="mods-available" ;;
            */conf.d/*) cat="conf.d" ;;
            *) cat="unknown" ;;
        esac

        # Is it actually active (loaded by Apache)?
        enabled="no"
        case "$cat" in
            conf-enabled|sites-enabled|mods-enabled|master|conf.d) enabled="yes" ;;
            conf-available|sites-available|mods-available)
                # If a symlink exists in enabled -> yes
                local base name="no"
                base=$(basename "$f")
                for edir in conf-enabled sites-enabled mods-enabled; do
                    if [[ -e "$(dirname "$(dirname "$f")")/$edir/$base" ]]; then
                        name="yes"; break
                    fi
                done
                enabled="$name"
                ;;
        esac

        printf '%s\t%s\t%s\n' "$cat" "$f" "$enabled"
    done < <(grep -rlZiE '^\s*MDomain[s]?\b' "${roots[@]}" 2>/dev/null)
}

# -------- Apache: deactivate MDomain in any location --------
# Called only after user confirmation. Dry-run-safe.
# cb_apache_disable_md_source CATEGORY FILE
cb_apache_disable_md_source() {
    local cat="$1" f="$2"
    [[ -z "$f" || ! -e "$f" ]] && return 1

    case "$cat" in
        disabled)
            return 0  # already inactive
            ;;
        conf-enabled|sites-enabled|mods-enabled)
            # Symlink - has path in available/, use a2disconf/a2dissite/a2dismod
            local base; base=$(basename "$f" .conf)
            local cmd
            case "$cat" in
                conf-enabled)   cmd="a2disconf" ;;
                sites-enabled)  cmd="a2dissite" ;;
                mods-enabled)   cmd="a2dismod"  ;;
            esac
            if command -v "$cmd" >/dev/null 2>&1; then
                [[ "$CB_DRY_RUN" == "0" ]] && "$cmd" "$base" >/dev/null 2>&1
                cb_log "Deactivated ($cmd $base)"
                return 0
            fi
            # Fallback: simply remove symlink
            if [[ -L "$f" && "$CB_DRY_RUN" == "0" ]]; then
                rm -f "$f"
                cb_log "Removed symlink: $f"
                return 0
            fi
            ;;
        conf-available|sites-available|mods-available)
            # This is not active (unless it also exists in enabled),
            # but on the next a2enconf/a2ensite it would be activated.
            # Comment out MDomain lines.
            [[ "$CB_DRY_RUN" == "0" ]] && {
                cp "$f" "$f.bak_$(date +%s)"
                sed -i 's/^\(\s*MDomain\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDContactEmail\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDMessageCMD\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDCertificateAuthority\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDExternalAccountBinding\)/#CERTBERUS-DISABLED# \1/' "$f"
            }
            cb_log "Commented out MDomain in: $f"
            return 0
            ;;
        master|conf.d|unknown)
            # apache2.conf or similar broken placements.
            # Comment out MDomain lines (keep the rest).
            [[ "$CB_DRY_RUN" == "0" ]] && {
                cp "$f" "$f.bak_$(date +%s)"
                sed -i 's/^\(\s*MDomain\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDContactEmail\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDMessageCMD\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDCertificateAuthority\)/#CERTBERUS-DISABLED# \1/' "$f"
                sed -i 's/^\(\s*MDExternalAccountBinding\)/#CERTBERUS-DISABLED# \1/' "$f"
            }
            cb_log "Commented out MDomain in: $f (master/unknown)"
            return 0
            ;;
    esac
    return 1
}

# -------- Apache: SSLCertificateFile path validation --------
# Finds all SSLCertificateFile and SSLCertificateKeyFile in conf-enabled/sites-enabled
# and checks that the file exists. If not -> replaces with snakeoil (or self-signed
# generated ad-hoc if ssl-cert package is not installed).
# Returns the number of fixed vhosts.
cb_apache_fix_ssl_cert_paths() {
    local apache_root="${1:-/etc/apache2}"
    local snake_cert=/etc/ssl/certs/ssl-cert-snakeoil.pem
    local snake_key=/etc/ssl/private/ssl-cert-snakeoil.key
    local fixed=0

    [[ -d "$apache_root" ]] || { echo 0; return 0; }

    # If snakeoil does not exist, generate our own self-signed (openssl is
    # part of apache2-bin deps, so it is always available).
    if [[ ! -r "$snake_cert" || ! -r "$snake_key" ]]; then
        snake_cert="${CB_STATE_DIR:-/var/lib/certberus}/fallback-cert.pem"
        snake_key="${CB_STATE_DIR:-/var/lib/certberus}/fallback-key.pem"
        if [[ ! -r "$snake_cert" || ! -r "$snake_key" ]]; then
            if [[ "$CB_DRY_RUN" == "0" ]] && command -v openssl >/dev/null 2>&1; then
                mkdir -p "$(dirname "$snake_cert")" 2>/dev/null
                openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                    -keyout "$snake_key" -out "$snake_cert" \
                    -subj "/CN=certberus-fallback" >/dev/null 2>&1 && \
                    chmod 600 "$snake_key"
            fi
        fi
    fi

    local files f
    mapfile -t files < <(find "$apache_root/sites-enabled" "$apache_root/conf-enabled" \
        -maxdepth 2 -type l -o -type f 2>/dev/null | sort -u)

    for f in "${files[@]}"; do
        [[ -r "$f" ]] || continue
        # Actual path (resolve symlinks)
        local real; real=$(readlink -f "$f" 2>/dev/null || echo "$f")
        [[ -r "$real" ]] || continue

        local needs_fix=0 line_cert line_key
        # One awk call instead of 2x grep|head|awk - saves ~4 forks per file
        read -r line_cert line_key < <(awk '
            /^[[:space:]]*SSLCertificateFile[[:space:]]+/ && !c { c=$2 }
            /^[[:space:]]*SSLCertificateKeyFile[[:space:]]+/ && !k { k=$2 }
            END { print (c ? c : "-") " " (k ? k : "-") }
        ' "$real" 2>/dev/null)
        [[ "$line_cert" == "-" ]] && line_cert=""
        [[ "$line_key"  == "-" ]] && line_key=""

        if _cb_ssl_path_invalid "$line_cert"; then
            needs_fix=1
            cb_warn "Invalid SSLCertificateFile in $real: $line_cert" >&2
        fi
        if _cb_ssl_path_invalid "$line_key"; then
            needs_fix=1
            cb_warn "Invalid SSLCertificateKeyFile in $real: $line_key" >&2
        fi

        if (( needs_fix )) && [[ -r "$snake_cert" && -r "$snake_key" ]]; then
            if [[ "$CB_DRY_RUN" == "0" ]]; then
                cp "$real" "$real.bak_$(date +%s)"
                sed -i -E "s|^(\s*SSLCertificateFile\s+).*|\1$snake_cert|" "$real"
                sed -i -E "s|^(\s*SSLCertificateKeyFile\s+).*|\1$snake_key|" "$real"
            fi
            cb_ok "  -> $real replaced with snakeoil" >&2
            fixed=$((fixed+1))
        fi
    done
    echo "$fixed"
}

# -------- Apache: broken symlinks v *-enabled --------
cb_apache_find_broken_symlinks() {
    local root="${1:-/etc/apache2}"
    [[ -d "$root" ]] || return 0
    find "$root"/sites-enabled "$root"/conf-enabled "$root"/mods-enabled \
        -maxdepth 1 -xtype l 2>/dev/null
}

# -------- Apache: fix broken symlinks (removal) --------
# Returns the number of removed
cb_apache_fix_broken_symlinks() {
    local root="${1:-/etc/apache2}"
    local fixed=0 f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ "$CB_DRY_RUN" == "1" ]]; then
            cb_log "[DRY-RUN] rm broken symlink: $f"
        else
            rm -f "$f" && cb_ok "  -> removed broken symlink: $f" >&2
        fi
        fixed=$((fixed+1))
    done < <(cb_apache_find_broken_symlinks "$root")
    echo "$fixed"
}

# -------- Apache: sites-enabled regular file (non-symlink) --------
# On Debian/Ubuntu, Apache has sites-enabled as pure symlinks to sites-available.
# Broken state: someone placed a regular file directly into sites-enabled -> admin cannot
# use a2dissite. Certberus fixes this: move to sites-available + a2ensite.
# Returns the number of fixed files.
cb_apache_fix_sites_enabled_regular_files() {
    local root="${1:-/etc/apache2}"
    local fixed=0 dir base target
    [[ -d "$root" ]] || { echo 0; return 0; }

    # Iterate over sites-enabled, conf-enabled - mods-enabled we handle symlinks only
    for dir in sites-enabled conf-enabled; do
        [[ -d "$root/$dir" ]] || continue
        local avail="${dir%-enabled}-available"
        [[ -d "$root/$avail" ]] || continue

        while IFS= read -r f; do
            [[ -f "$f" && ! -L "$f" ]] || continue   # regular files only, not symlinks
            base=$(basename "$f")
            target="$root/$avail/$base"

            cb_warn "Bad state: regular file in $dir/: $f"
            if [[ -e "$target" && ! -L "$target" ]]; then
                # Something already there — backup and overwrite? Better not.
                cb_warn "  -> $target already exists, doing nothing (inspect manually)"
                continue
            fi

            if [[ "$CB_DRY_RUN" == "1" ]]; then
                cb_log "[DRY-RUN] mv $f -> $target; symlink back"
                fixed=$((fixed+1))
                continue
            fi

            # Backup for safety
            cp "$f" "${f}.bak_$(date +%s)" 2>/dev/null || true
            if mv "$f" "$target" 2>/dev/null && \
               ln -sf "../$avail/$base" "$f" 2>/dev/null; then
                cb_ok "  -> moved to $avail/ and symlinked back"
                fixed=$((fixed+1))
            else
                cb_error "  -> move failed, reverting"
                [[ -f "$target" ]] && mv "$target" "$f" 2>/dev/null
            fi
        done < <(find "$root/$dir" -maxdepth 1 -type f ! -name '*.bak_*' 2>/dev/null)
    done
    echo "$fixed"
}

# -------- Apache master check --------
# Returns: 0 = OK, 1 = warning (fixable), 2 = fatal
cb_preflight_apache() {
    local rc=0 apachectl
    for c in apache2ctl apachectl httpd; do
        command -v "$c" >/dev/null 2>&1 && { apachectl="$c"; break; }
    done
    [[ -z "${apachectl:-}" ]] && return 0  # Apache not installed — clean start

    cb_sep
    cb_log "Pre-flight: Apache"

    # 1) Syntax check
    local synerr
    synerr=$("$apachectl" -t 2>&1)
    if ! "$apachectl" -t >/dev/null 2>&1; then
        cb_warn "Apache configuration has a syntax error:"
        echo "$synerr" | sed 's/^/    /' | head -10
        rc=1
    fi

    # 2) Broken symlinks
    local broken
    broken=$(cb_apache_find_broken_symlinks)
    if [[ -n "$broken" ]]; then
        cb_warn "Broken symlinks in Apache:"
        echo "$broken" | sed 's/^/    /'
        rc=1
    fi

    # 3) Existing MDomain - detailed listing
    local md_sources
    md_sources=$(cb_apache_md_sources)
    if [[ -n "$md_sources" ]]; then
        cb_log "Found existing MDomain configuration:"
        echo "$md_sources" | while IFS=$'\t' read -r cat path en; do
            printf '    [%s %s] %s\n' "$cat" "$en" "$path"
        done
    fi

    # 4) Invalid SSL paths - only report what is wrong, fix later on demand
    if [[ -d /etc/apache2 || -d /etc/httpd ]]; then
        local bad_paths=""
        local apache_root=/etc/apache2
        [[ -d /etc/httpd ]] && apache_root=/etc/httpd

        while IFS= read -r f; do
            [[ -r "$f" ]] || continue
            local real; real=$(readlink -f "$f" 2>/dev/null)
            [[ -r "$real" ]] || continue
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                [[ -r "$p" ]] && continue
                bad_paths="${bad_paths}  $real: $p\n"
            done < <(grep -hE '^\s*SSLCertificate(File|KeyFile)\s+' "$real" 2>/dev/null | awk '{print $2}')
        done < <(find "$apache_root"/sites-enabled "$apache_root"/conf-enabled \
                    -maxdepth 2 \( -type l -o -type f \) 2>/dev/null)

        if [[ -n "$bad_paths" ]]; then
            cb_warn "Invalid SSLCertificate paths (fixable with snakeoil):"
            printf "$bad_paths"
            rc=1
        fi
    fi

    # 5) If no errors
    (( rc == 0 )) && cb_ok "Apache pre-flight: OK"
    return "$rc"
}

# -------- Nginx preflight --------
cb_preflight_nginx() {
    command -v nginx >/dev/null 2>&1 || return 0
    local rc=0
    cb_sep
    cb_log "Pre-flight: nginx"

    local synerr
    synerr=$(nginx -t 2>&1)
    if ! nginx -t >/dev/null 2>&1; then
        cb_warn "nginx configuration has a syntax error:"
        echo "$synerr" | sed 's/^/    /' | head -10
        # Try to find the specific vhost file with the error (from stderr).
        local broken_vhosts=()
        while IFS= read -r line; do
            broken_vhosts+=("$line")
        done < <(echo "$synerr" | grep -oE '/etc/nginx/sites-enabled/[^:"]+' | sort -u)
        if (( ${#broken_vhosts[@]} > 0 )); then
            cb_warn "Files causing the error:"
            printf '    %s\n' "${broken_vhosts[@]}"
            cb_warn "Suggestion: temporarily deactivate (mv) before issuing cert:"
            for f in "${broken_vhosts[@]}"; do
                cb_warn "    sudo mv '$f' '${f%.conf}.disabled'"
            done
        fi
        rc=1
    fi

    # Invalid ssl_certificate
    local bad=""
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        [[ -r "$p" ]] && continue
        bad="${bad}  $p\n"
    done < <(nginx -T 2>/dev/null | awk '/^\s*ssl_certificate(_key)?\s/ {sub(/;.*$/,""); print $2}' | sort -u)
    if [[ -n "$bad" ]]; then
        cb_warn "Invalid ssl_certificate paths in nginx config:"
        printf "$bad"
        rc=1
    fi

    (( rc == 0 )) && cb_ok "nginx pre-flight: OK"
    return "$rc"
}

# -------- Tomcat preflight --------
cb_preflight_tomcat() {
    local svc
    svc=$(systemctl list-unit-files 2>/dev/null | awk '/^tomcat[0-9]*\.service/ {print $1; exit}')
    [[ -z "$svc" ]] && return 0
    cb_sep
    cb_log "Pre-flight: Tomcat ($svc)"

    local xml=""
    for p in /etc/tomcat*/server.xml /opt/tomcat*/conf/server.xml /var/lib/tomcat*/conf/server.xml; do
        [[ -f "$p" ]] && { xml="$p"; break; }
    done
    if [[ -z "$xml" ]]; then
        cb_warn "server.xml not found"
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import xml.etree.ElementTree as E; E.parse('$xml')" 2>/dev/null; then
            cb_warn "server.xml ($xml) is not valid XML"
            return 2
        fi
    fi
    cb_ok "Tomcat pre-flight: OK ($xml)"
    return 0
}
