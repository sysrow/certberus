#!/bin/bash
# certberus/lib/scan.sh
# Cross-server certificate inventory.
#
# Idea: on an unknown machine, quickly find WHERE X.509 certs/keys reside, which
# domain they serve, and what deploys them. Covers:
#
#   - Files: PEM/DER (.crt .pem .cer .der) + PKCS#12 (.p12 .pfx) + JKS (.jks)
#     in typical directories /etc/ssl, /etc/pki, /etc/letsencrypt, /etc/apache2/md, ...
#   - References in webserver config files (apache, nginx, tomcat, haproxy,
#     postfix, dovecot, exim, openvpn, strongswan, mysql, postgres, slapd, bind, ...).
#   - Live listeners (ss -tlnp / netstat) + openssl s_client probe for ports
#     443/465/636/853/989/990/993/995/3306/5432/5671/8443/27017 etc.
#
# Output:
#   table (default) | json | tsv
#
# Why bash and not rust:
#   - Workload is I/O-bound (find traversal + openssl x509 fork). Rust would not speed it up.
#   - Certberus is a drop-in single-file bundle - adding a Rust binary would break
#     the "scp to server, chmod +x, done" simplicity.
#   - Adds to the bundle without dependencies.
#
# Bash-only constraints:
#   - openssl as parser (not custom ASN.1)
#   - keytool (Java) is optional; if missing, JKS is reported as "encrypted blob"
#   - PKCS#12 parsing requires openssl pkcs12; if cert is password-protected, we report it
[[ -n "${_CB_SCAN_LOADED:-}" ]] && return 0
_CB_SCAN_LOADED=1

# ---------------- Paths for find ---------------------------------------------
# Standard locations for finding cert files. Covers 99% of Linux servers.
# Admin can override via CB_SCAN_PATHS="path1:path2:..." (PATH-style).
_CB_SCAN_DEFAULT_PATHS=(
    /etc/ssl /etc/pki /etc/letsencrypt /etc/certs
    /etc/apache2 /etc/httpd /etc/nginx /etc/lighttpd /etc/caddy
    /etc/haproxy /etc/stunnel
    /etc/postfix /etc/dovecot /etc/exim4 /etc/exim
    /etc/openvpn /etc/strongswan /etc/ipsec.d /etc/wireguard
    /etc/mysql /etc/postgresql /etc/redis /etc/mongodb /etc/rabbitmq
    /etc/bind /etc/named /etc/powerdns /etc/pdns
    /etc/openldap /etc/ldap /etc/cyrus /etc/proftpd /etc/vsftpd
    /etc/asterisk /etc/freeswitch
    /etc/squid /etc/varnish
    # Java/Tomcat/WebLogic typical paths
    /opt/tomcat /usr/share/tomcat* /var/lib/tomcat*
    /opt/wildfly /opt/jboss /opt/weblogic /u01/app/oracle
    /opt/openjdk* /usr/lib/jvm
    # Custom app deployments
    /opt /srv /var/www
)

# Configuration files + regex representing cert/key path.
# Format: <glob> <regex>
# Regex MUST have one group that contains the filepath.
_CB_SCAN_CONFIG_REFS=(
    # Apache
    "/etc/apache2/**/*.conf|^[[:space:]]*SSLCertificate(File|KeyFile|ChainFile)[[:space:]]+\"?([^\"]+)\"?"
    "/etc/httpd/**/*.conf|^[[:space:]]*SSLCertificate(File|KeyFile|ChainFile)[[:space:]]+\"?([^\"]+)\"?"
    "/etc/apache2/**/*.conf|^[[:space:]]*MDCertificateAgreement|MDStoreDir[[:space:]]+\"?([^\"]+)\"?"
    # nginx
    "/etc/nginx/**/*.conf|^[[:space:]]*ssl_(certificate|certificate_key|trusted_certificate)[[:space:]]+\"?([^\";]+)\"?"
    # Tomcat
    "/opt/tomcat/**/server.xml|(certificateKeystoreFile|keystoreFile|certificateFile|certificateKeyFile)=\"([^\"]+)\""
    "/var/lib/tomcat*/**/server.xml|(certificateKeystoreFile|keystoreFile|certificateFile|certificateKeyFile)=\"([^\"]+)\""
    "/etc/tomcat*/**/server.xml|(certificateKeystoreFile|keystoreFile|certificateFile|certificateKeyFile)=\"([^\"]+)\""
    # HAProxy: 'bind ... ssl crt /path/to/bundle.pem'
    "/etc/haproxy/**/*.cfg|[[:space:]]ssl[[:space:]]+crt[[:space:]]+([^[:space:]]+)"
    # Postfix
    "/etc/postfix/**/main.cf|^[[:space:]]*smtpd?_tls_(cert|key|chain)_file[[:space:]]*=[[:space:]]*([^[:space:]]+)"
    # Dovecot
    "/etc/dovecot/**/*.conf*|^[[:space:]]*ssl_(cert|key)[[:space:]]*=[[:space:]]*<?([^[:space:]]+)"
    # Exim
    "/etc/exim*/**/*.conf*|^[[:space:]]*tls_(certificate|privatekey)[[:space:]]*=[[:space:]]*([^[:space:]]+)"
    # OpenVPN
    "/etc/openvpn/**/*.conf|^[[:space:]]*(cert|key|ca|tls-auth)[[:space:]]+([^[:space:]]+)"
    # MySQL/MariaDB
    "/etc/mysql/**/*.cnf|^[[:space:]]*ssl[-_](cert|key|ca)[[:space:]]*=[[:space:]]*([^[:space:]]+)"
    # PostgreSQL
    "/etc/postgresql/**/postgresql.conf|^[[:space:]]*ssl_(cert|key|ca)_file[[:space:]]*=[[:space:]]*'?([^']+)"
    # OpenLDAP / slapd
    "/etc/openldap/**/*.conf|^[[:space:]]*olcTLS(Certificate|CertificateKey|CACertificate)File:[[:space:]]+([^[:space:]]+)"
    # Bind / named
    "/etc/bind/**/*.conf|tls-(certificate|key)-file[[:space:]]+\"?([^\";]+)\"?"
    # PowerDNS
    "/etc/powerdns/**/*.conf|^[[:space:]]*(api-key|x509-cert|x509-key)[[:space:]]*=[[:space:]]*([^[:space:]]+)"
    # ProFTPD / vsftpd
    "/etc/proftpd/**/*.conf|^[[:space:]]*TLS(Required|RSACertificateFile|RSACertificateKeyFile)[[:space:]]+\"?([^\"]+)\"?"
    "/etc/vsftpd*.conf|^[[:space:]]*(rsa_cert_file|rsa_private_key_file)=([^[:space:]]+)"
)

# Network listeners to probe (port:description). 'auto' mode probes active TCP listeners.
_CB_SCAN_TLS_PORTS=(
    "443:HTTPS" "465:SMTPS" "636:LDAPS" "853:DoT" "989:FTPS-data" "990:FTPS"
    "993:IMAPS" "995:POP3S" "8443:Alt-HTTPS" "5061:SIPS"
    "27017:MongoDB-TLS" "5671:AMQP-TLS" "5432:PostgreSQL"
    "3306:MySQL" "9200:Elasticsearch" "9093:Kafka-TLS"
)

# ---------------- Helpery -----------------------------------------------------

# Returns paths to certificate files (FS traversal).
# stdout: one file per line
_cb_scan_find_files() {
    local -a roots=()
    if [[ -n "${CB_SCAN_PATHS:-}" ]]; then
        IFS=':' read -r -a roots <<<"$CB_SCAN_PATHS"
    else
        roots=("${_CB_SCAN_DEFAULT_PATHS[@]}")
    fi

    # Expand glob (e.g. /usr/share/tomcat*) and filter non-existing
    local -a real_roots=()
    local r expanded
    for r in "${roots[@]}"; do
        # shellcheck disable=SC2206
        expanded=( $r )  # glob expansion; usually reasonable - no user-supplied chars
        for e in "${expanded[@]}"; do
            [[ -d "$e" ]] && real_roots+=("$e")
        done
    done
    (( ${#real_roots[@]} == 0 )) && return 0

    # Known X.509 file extensions. Symlinks are followed, but only once (-L in find)
    # could cause loops; safer to skip -L and track manually. Default without -L.
    find "${real_roots[@]}" -type f \( \
        -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.der' \
        -o -name '*.cert' -o -name '*.p12' -o -name '*.pfx' \
        -o -name '*.jks' -o -name '*.keystore' \
        -o -name 'fullchain' -o -name 'cert.pem' -o -name 'pubcert.pem' \
        -o -name 'fullchain.pem' -o -name 'privkey.pem' \
    \) 2>/dev/null
}

# Find cert/key references in config files.
# stdout: tab-separated:  <config-file>\t<referenced-cert-path>\t<role>
_cb_scan_find_refs() {
    local entry pattern path_glob regex matched
    local prefix="${CB_SCAN_ROOT:-}"
    for entry in "${_CB_SCAN_CONFIG_REFS[@]}"; do
        path_glob="${entry%%|*}"
        regex="${entry#*|}"
        # CB_SCAN_ROOT allows tests / chroot environments to redirect /etc/* to a sandbox.
        [[ -n "$prefix" ]] && path_glob="${prefix}${path_glob}"
        # Find configs. find with -path glob does not support **; we use bash extglob.
        # Safe glob-to-find conversion: create root + -name for the last component.
        local root="${path_glob%%/\*\**}"
        [[ "$root" == "$path_glob" ]] && root=$(dirname "$path_glob")
        [[ -d "$root" ]] || continue
        local last="${path_glob##*/}"
        # POSIX find -name accepts '*.conf' etc; '/**/' in our pattern means depth
        while IFS= read -r f; do
            [[ -r "$f" ]] || continue
            # GNU grep -P is not available everywhere, using bash regex
            local line
            while IFS= read -r line; do
                if [[ "$line" =~ $regex ]]; then
                    # match group #2 contains the path (group #1 is usually role)
                    local role="${BASH_REMATCH[1]:-}"
                    local target="${BASH_REMATCH[2]:-${BASH_REMATCH[1]:-}}"
                    [[ -z "$target" ]] && continue
                    # Handles relative paths + Apache "Include" is out of scope
                    printf '%s\t%s\t%s\n' "$f" "$target" "$role"
                fi
            done < "$f"
        done < <(find "$root" -type f -name "$last" 2>/dev/null)
    done
}

# Probe TLS listener: openssl s_client -connect host:port
# stdout: subject\tissuer\tnotAfter
_cb_scan_probe_listener() {
    local host="$1" port="$2"
    command -v openssl >/dev/null 2>&1 || return 1
    local out
    out=$(timeout 5 openssl s_client -servername "$host" -connect "$host:$port" \
            </dev/null 2>/dev/null \
            | timeout 3 openssl x509 -noout -subject -issuer -dates 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1
    local subj iss notafter
    subj=$(echo "$out" | sed -n 's/^subject= *//p')
    iss=$(echo "$out" | sed -n 's/^issuer= *//p')
    notafter=$(echo "$out" | sed -n 's/^notAfter= *//p')
    printf '%s\t%s\t%s\n' "$subj" "$iss" "$notafter"
}

# Find active TLS listeners (LISTEN ports against _CB_SCAN_TLS_PORTS).
# stdout: addr:port
_cb_scan_active_listeners() {
    local out
    if command -v ss >/dev/null 2>&1; then
        out=$(ss -tlnH 2>/dev/null | awk '{print $4}')
    elif command -v netstat >/dev/null 2>&1; then
        out=$(netstat -tlnH 2>/dev/null | awk 'NR>2 {print $4}')
    else
        return 1
    fi
    local p line
    while IFS= read -r line; do
        # parse the last number after ':' as port
        port="${line##*:}"
        for p in "${_CB_SCAN_TLS_PORTS[@]}"; do
            if [[ "${p%%:*}" == "$port" ]]; then
                echo "$line"
                break
            fi
        done
    done <<<"$out"
}

# Parses X.509 cert from a file. Input can be PEM/DER/PKCS#12/JKS.
# Outputs: <kind>\t<subject>\t<issuer>\t<notAfter>\t<sha256-fp>\t<sans>
# kind: pem|der|pkcs12|jks|encrypted|unknown
#
# IMPORTANT: ALL openssl invocations must have </dev/null + timeout, otherwise
# scan hangs on password-protected files (openssl pkcs12 / x509 /
# rsa can read password from /dev/tty). Before fix, 'certberus scan' hung when
# it hit a cert/key with password -- openssl prompt blocked the entire run.
# We use heredoc-style </dev/null so openssl detects closed stdin
# and instead of prompting immediately exits with an error (which we swallow
# via 2>&1 and ignore).
_cb_scan_parse_cert_file() {
    local f="$1"
    [[ -r "$f" ]] || { printf '%s\t%s\t%s\t%s\t%s\t%s\n' unreadable - - - - -; return; }

    # Size - extremely large files (>16MB) are skipped, x509 store /
    # CRL bundles are not of interest and would hurt performance.
    local sz
    sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 16777216 )); then
        printf 'too-large\t-\t-\t-\t-\t-\n'; return
    fi

    local first
    first=$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')

    # PKCS#12 / JKS detection by extension MUST be BEFORE DER check, otherwise .p12
    # (starts with 30 82 just like DER cert) passes through the DER branch as 'der-unknown'
    # and more importantly openssl x509 -inform DER can in openssl 3.x trigger a PKCS#12
    # password prompt on /dev/tty.
    case "$f" in
        *.p12|*.pfx)
            local txt try_pass
            for try_pass in '' 'changeit' 'password'; do
                txt=$(timeout 5 openssl pkcs12 -in "$f" -nokeys -passin "pass:$try_pass" -nomacver </dev/null 2>/dev/null \
                      | timeout 5 openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
                [[ -n "$txt" ]] && break
            done
            if [[ -n "$txt" ]]; then
                printf 'pkcs12\t%s\t%s\t%s\t-\t-\n' \
                    "$(echo "$txt"|sed -n 's/^subject= *//p'|head -1)" \
                    "$(echo "$txt"|sed -n 's/^issuer= *//p'|head -1)" \
                    "$(echo "$txt"|sed -n 's/^notAfter= *//p'|head -1)"
            else
                printf 'pkcs12-encrypted\t-\t-\t-\t-\t(password-protected, use openssl pkcs12 -in %s)\n' "$f"
            fi
            return
            ;;
        *.jks|*.keystore)
            if command -v keytool >/dev/null 2>&1; then
                local lst try_pass
                for try_pass in 'changeit' 'password' ''; do
                    lst=$(timeout 5 keytool -list -keystore "$f" -storepass "${try_pass:-changeit}" </dev/null 2>/dev/null \
                          | grep -E 'Owner:|Issuer:|Valid from:' | head -10)
                    [[ -n "$lst" ]] && break
                done
                if [[ -n "$lst" ]]; then
                    printf 'jks\t-\t-\t-\t-\t%s\n' "$(echo "$lst" | tr '\n' ';' )"
                else
                    printf 'jks-encrypted\t-\t-\t-\t-\t(password-protected, try keytool -list -keystore %s)\n' "$f"
                fi
            else
                printf 'jks\t-\t-\t-\t-\t(keytool not installed)\n'
            fi
            return
            ;;
    esac

    # PEM (---)
    if head -1 "$f" 2>/dev/null | grep -q -- '-----BEGIN'; then
        # Detect ENCRYPTED block: Proc-Type: 4,ENCRYPTED (PKCS#1) or
        # BEGIN ENCRYPTED PRIVATE KEY (PKCS#8). openssl x509 ignores these,
        # but better to report them so they appear in the output.
        local has_encrypted_block=0
        if grep -q -E -- '-----BEGIN ENCRYPTED PRIVATE KEY-----|^Proc-Type: 4,ENCRYPTED' "$f" 2>/dev/null; then
            has_encrypted_block=1
        fi
        # Maybe the file only contains a key. Try cert first.
        # </dev/null + timeout 5: if openssl wanted to read passphrase for any
        # reason (corrupted PEM, atypical encrypted cert), it does not wait.
        local txt
        txt=$(timeout 5 openssl x509 -in "$f" -noout -subject -issuer -enddate -fingerprint -sha256 -ext subjectAltName </dev/null 2>/dev/null)
        if [[ -z "$txt" ]]; then
            if (( has_encrypted_block )); then
                printf 'pem-key-encrypted\t-\t-\t-\t-\t(password-protected key, scan skipped)\n'
            elif grep -q 'PRIVATE KEY' "$f" 2>/dev/null; then
                printf 'pem-key\t-\t-\t-\t-\t-\n'
            else
                printf 'pem-other\t-\t-\t-\t-\t-\n'
            fi
            return
        fi
        local subj iss notafter fp sans
        subj=$(echo "$txt" | sed -n 's/^subject= *//p; s/^subject=//p' | head -1)
        iss=$(echo "$txt"  | sed -n 's/^issuer= *//p; s/^issuer=//p'   | head -1)
        notafter=$(echo "$txt" | sed -n 's/^notAfter= *//p; s/^notAfter=//p' | head -1)
        fp=$(echo "$txt" | sed -n 's/^SHA256 Fingerprint=//p' | tr -d ':')
        sans=$(echo "$txt" | awk '/X509v3 Subject Alternative Name/{getline; print}' | sed 's/^[[:space:]]*//; s/, /,/g')
        printf 'pem\t%s\t%s\t%s\t%s\t%s\n' "${subj:--}" "${iss:--}" "${notafter:--}" "${fp:--}" "${sans:--}"
        return
    fi

    # DER (starts with 30 82 ... ASN.1 SEQUENCE)
    if [[ "${first:0:4}" == "3082" ]]; then
        local txt
        txt=$(timeout 5 openssl x509 -inform DER -in "$f" -noout -subject -issuer -enddate -fingerprint -sha256 </dev/null 2>/dev/null)
        if [[ -n "$txt" ]]; then
            local subj iss notafter fp
            subj=$(echo "$txt" | sed -n 's/^subject= *//p' | head -1)
            iss=$(echo "$txt"  | sed -n 's/^issuer= *//p'  | head -1)
            notafter=$(echo "$txt" | sed -n 's/^notAfter= *//p' | head -1)
            fp=$(echo "$txt" | sed -n 's/^SHA256 Fingerprint=//p' | tr -d ':')
            printf 'der\t%s\t%s\t%s\t%s\t-\n' "${subj:--}" "${iss:--}" "${notafter:--}" "${fp:--}"
            return
        fi
        printf 'der-unknown\t-\t-\t-\t-\t-\n'
        return
    fi

    printf 'unknown\t-\t-\t-\t-\t-\n'
}

# ---------------- Public interface -------------------------------------------
# cb_scan [--format table|json|tsv] [--no-fs] [--no-config] [--no-listen]
cb_scan() {
    local fmt="table"
    local do_fs=1 do_config=1 do_listen=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) shift; fmt="$1" ;;
            --no-fs) do_fs=0 ;;
            --no-config) do_config=0 ;;
            --no-listen) do_listen=0 ;;
            -h|--help)
                cat <<EOF
certberus scan - X.509 inventory on the machine

Options:
  --format table|json|tsv     output format (default: table)
  --no-fs       skip filesystem file scanning
  --no-config   skip webserver config parsing
  --no-listen   skip TLS listener probe

Variables:
  CB_SCAN_PATHS=path1:path2  override default paths for find (PATH-style)
EOF
                return 0 ;;
            *) cb_warn "scan: unknown flag '$1'"; return 2 ;;
        esac
        shift
    done

    case "$fmt" in
        table|json|tsv) ;;
        *) cb_warn "invalid format: $fmt"; return 2 ;;
    esac

    if ! command -v openssl >/dev/null 2>&1; then
        cb_error "openssl is not in PATH - scan requires openssl for certificate parsing"
        return 1
    fi

    [[ "$fmt" == "table" ]] && cb_log "== Certberus scan (host=$(hostname 2>/dev/null || echo ?)) =="

    local first_section=1
    _section() {
        if [[ "$fmt" == "table" ]]; then
            (( first_section == 0 )) && cb_sep || first_section=0
            cb_log "$1"
        fi
    }

    # 1. Filesystem
    if (( do_fs )); then
        _section "[1] X.509 files on FS"
        if [[ "$fmt" == "table" ]]; then
            printf "  %-60s %-10s %s\n" "PATH" "KIND" "SUBJECT/EXPIRY"
        fi
        local count=0
        while IFS= read -r f; do
            (( count++ ))
            local meta; meta=$(_cb_scan_parse_cert_file "$f")
            local kind subj iss notafter fp sans
            IFS=$'\t' read -r kind subj iss notafter fp sans <<<"$meta"
            case "$fmt" in
                table)
                    printf "  %-60s %-10s %s | %s\n" \
                        "${f:0:60}" "$kind" "${subj:0:50}" "exp=$notafter"
                    ;;
                tsv)  printf 'fs\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$kind" "$subj" "$iss" "$notafter" "$fp" ;;
                json)
                    printf '{"source":"fs","path":%s,"kind":%s,"subject":%s,"issuer":%s,"notAfter":%s,"sha256":%s,"sans":%s}\n' \
                        "$(_cb_scan_jq "$f")" "$(_cb_scan_jq "$kind")" \
                        "$(_cb_scan_jq "$subj")" "$(_cb_scan_jq "$iss")" \
                        "$(_cb_scan_jq "$notafter")" "$(_cb_scan_jq "$fp")" \
                        "$(_cb_scan_jq "$sans")"
                    ;;
            esac
        done < <(_cb_scan_find_files)
        [[ "$fmt" == "table" ]] && cb_log "  -> $count files"
    fi

    # 2. Config references
    if (( do_config )); then
        _section "[2] References in configurations"
        if [[ "$fmt" == "table" ]]; then
            printf "  %-50s %-50s %s\n" "CONFIG" "REFERENCED PATH" "ROLE"
        fi
        local cnt=0
        while IFS=$'\t' read -r cfg target role; do
            (( cnt++ ))
            case "$fmt" in
                table) printf "  %-50s %-50s %s\n" "${cfg:0:50}" "${target:0:50}" "$role" ;;
                tsv)   printf 'config\t%s\t%s\t%s\n' "$cfg" "$target" "$role" ;;
                json)  printf '{"source":"config","config":%s,"path":%s,"role":%s}\n' \
                            "$(_cb_scan_jq "$cfg")" "$(_cb_scan_jq "$target")" "$(_cb_scan_jq "$role")" ;;
            esac
        done < <(_cb_scan_find_refs)
        [[ "$fmt" == "table" ]] && cb_log "  -> $cnt references"
    fi

    # 3. Live listenery
    if (( do_listen )); then
        _section "[3] Active TLS listeners"
        local lst
        lst=$(_cb_scan_active_listeners 2>/dev/null || true)
        if [[ -z "$lst" ]]; then
            [[ "$fmt" == "table" ]] && cb_log "  (no TLS ports or ss/netstat missing)"
        else
            local addr port
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                port="${line##*:}"
                addr="${line%:*}"
                # Probe localhost (on external addresses hostname could fail)
                local probe
                probe=$(_cb_scan_probe_listener "127.0.0.1" "$port" 2>/dev/null || true)
                local subj="-" iss="-" notafter="-"
                if [[ -n "$probe" ]]; then
                    IFS=$'\t' read -r subj iss notafter <<<"$probe"
                fi
                case "$fmt" in
                    table) printf "  %-25s %-50s exp=%s\n" "$line" "${subj:0:50}" "$notafter" ;;
                    tsv)   printf 'listen\t%s\t%s\t%s\t%s\n' "$line" "$subj" "$iss" "$notafter" ;;
                    json)  printf '{"source":"listen","listen":%s,"subject":%s,"issuer":%s,"notAfter":%s}\n' \
                                "$(_cb_scan_jq "$line")" "$(_cb_scan_jq "$subj")" \
                                "$(_cb_scan_jq "$iss")" "$(_cb_scan_jq "$notafter")" ;;
                esac
            done <<<"$lst"
        fi
    fi

    return 0
}

# Mini JSON encoder - escapes only \ and "
_cb_scan_jq() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
