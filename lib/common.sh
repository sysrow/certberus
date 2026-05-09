#!/bin/bash
# certberus/lib/common.sh
# Shared utilities for all webserver modules.
# Sourced (not executed directly). Requires bash 4+.
#
# Provides:
#   - logging (file + syslog + stdout)
#   - ask_yn / ask_in / ask_secret (TTY-safe)
#   - take_snapshot / rollback
#   - validate_domain
#   - trap handling
#   - banner / sep
#
# Convention: all public functions start with cb_ (certberus), private with _cb_

# -------- Guard against double-sourcing --------
[[ -n "${_CB_COMMON_LOADED:-}" ]] && return 0
_CB_COMMON_LOADED=1

# -------- Defaults (can be overridden by config.env) --------
: "${CB_PREFIX:=/etc/certberus}"
: "${CB_LOG_DIR:=/var/log/certberus}"
: "${CB_BACKUP_DIR:=/var/backups/certberus}"
: "${CB_STATE_DIR:=/var/lib/certberus}"
: "${CB_HOOKS_DIR:=${CB_PREFIX}/hooks}"
: "${CB_CONFIG_FILE:=${CB_PREFIX}/config.env}"
: "${CB_ADVANCED_FILE:=${CB_PREFIX}/advanced.env}"
: "${CB_LOG_FILE:=${CB_LOG_DIR}/certberus.log}"
: "${CB_SYSLOG_TAG:=certberus}"
: "${CB_SYSLOG_ENABLED:=1}"
: "${CB_ASSUME_YES:=0}"
: "${CB_DRY_RUN:=0}"
: "${CB_STAGING:=0}"
: "${CB_VERBOSE:=0}"
: "${CB_COLOR:=auto}"

# -------- Colors --------
_cb_init_colors() {
    local use_color=0
    case "$CB_COLOR" in
        always) use_color=1 ;;
        never)  use_color=0 ;;
        auto)   [[ -t 1 ]] && use_color=1 ;;
    esac
    if (( use_color )); then
        CB_C_RED=$'\033[31m'; CB_C_GRN=$'\033[32m'; CB_C_YLW=$'\033[33m'
        CB_C_BLU=$'\033[34m'; CB_C_BLD=$'\033[1m';  CB_C_RST=$'\033[0m'
    else
        CB_C_RED=; CB_C_GRN=; CB_C_YLW=; CB_C_BLU=; CB_C_BLD=; CB_C_RST=
    fi
}
_cb_init_colors

# -------- Logging --------
_cb_ensure_log_dir() {
    [[ -d "$CB_LOG_DIR" ]] && return 0
    # Logs contain domains + IPs - not world-readable.
    (umask 027; mkdir -p "$CB_LOG_DIR" 2>/dev/null) || return 1
    chmod 0750 "$CB_LOG_DIR" 2>/dev/null || true
}

_cb_write_log() {
    local level="$1" msg="$2"
    local ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[$ts] [$level] $msg"
    # file
    if _cb_ensure_log_dir && { [[ ! -e "$CB_LOG_FILE" ]] || [[ -w "$CB_LOG_FILE" ]]; }; then
        echo "$line" >> "$CB_LOG_FILE" 2>/dev/null || true
    fi
    # syslog
    if [[ "$CB_SYSLOG_ENABLED" == "1" ]] && command -v logger >/dev/null 2>&1; then
        local prio="daemon.info"
        case "$level" in
            ERROR) prio="daemon.err"  ;;
            WARN)  prio="daemon.warning" ;;
            DEBUG) prio="daemon.debug" ;;
        esac
        logger -t "$CB_SYSLOG_TAG" -p "$prio" -- "$msg" 2>/dev/null || true
    fi
}

cb_log()   { _cb_write_log INFO  "$*"; echo "${CB_C_BLU}[INFO]${CB_C_RST}  $*"; }
cb_ok()    { _cb_write_log INFO  "$*"; echo "${CB_C_GRN}[ OK ]${CB_C_RST}  $*"; }
cb_warn()  { _cb_write_log WARN  "$*"; echo "${CB_C_YLW}[WARN]${CB_C_RST}  $*" >&2; }
cb_error() { _cb_write_log ERROR "$*"; echo "${CB_C_RED}[ERR ]${CB_C_RST}  $*" >&2; }
cb_debug() { [[ "$CB_VERBOSE" == "1" ]] || return 0; _cb_write_log DEBUG "$*"; echo "[DBG]   $*" >&2; }
cb_die()   { cb_error "$*"; exit 1; }

cb_sep() { printf '%s\n' "────────────────────────────────────────────────────────────────"; }
cb_banner() {
    cb_sep
    printf '%s%s%s\n' "${CB_C_BLD}" "$*" "${CB_C_RST}"
    cb_sep
}

# -------- TTY helpers --------
cb_has_tty() { [[ -t 0 ]] && [[ -r /dev/tty ]]; }

# Y/N prompt. Default is the uppercase letter. Return code 0=yes, 1=no.
# Usage:  cb_ask_yn "Continue?" "Y/n"
cb_ask_yn() {
    local prompt="$1" def="${2:-Y/n}" ans default_yes=0
    [[ "$def" =~ ^Y ]] && default_yes=1
    if [[ "$CB_ASSUME_YES" == "1" ]] || ! cb_has_tty; then
        return $(( default_yes ? 0 : 1 ))
    fi
    read -r -p "$prompt [$def]: " ans </dev/tty
    if [[ -z "$ans" ]]; then
        return $(( default_yes ? 0 : 1 ))
    fi
    [[ "$ans" =~ ^[Yy] ]]
}

# Text prompt with default.  cb_ask_in "Email" "admin@example.com"
cb_ask_in() {
    local prompt="$1" def="${2:-}" ans
    if [[ "$CB_ASSUME_YES" == "1" ]] || ! cb_has_tty; then
        printf '%s' "$def"
        return 0
    fi
    read -r -p "$prompt [$def]: " ans </dev/tty
    printf '%s' "${ans:-$def}"
}

# Secret prompt (password/HMAC) without echo.
cb_ask_secret() {
    local prompt="$1" ans
    if ! cb_has_tty; then
        cb_error "A TTY or flag is required to enter a secret value."
        return 1
    fi
    read -r -s -p "$prompt: " ans </dev/tty
    echo >/dev/tty
    printf '%s' "$ans"
}

# -------- Validation --------
cb_validate_domain() {
    local d="$1"
    # exclude wildcards (wildcard requires DNS-01 challenge, we do HTTP-01)
    [[ "$d" == \** ]] && return 2
    # FQDN regex: labels a-zA-Z0-9 with optional -, 2-63 chars, dot, TLD min 2 chars
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

cb_validate_email() {
    local e="$1"
    [[ "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# CLI override without an explosive number of flags.
# Accepts only CB_* variables to prevent overwriting PATH/BASH_ENV etc.
# Value is validated against whitelisted characters - an accidental $(rm -rf /)
# won't expand (printf -v is safe), but when sourcing CB_X in child scripts
# (apache-md.sh) it could end up in some eval/cmdline.
cb_apply_cli_set() {
    local assignment="$1"
    [[ "$assignment" == *=* ]] || cb_die "--set requires format CB_NAME=value"
    local key="${assignment%%=*}"
    local value="${assignment#*=}"
    [[ "$key" =~ ^CB_[A-Z0-9_]+$ ]] || cb_die "--set can only set CB_* variables (given: $key)"
    # Value whitelist: alphanumeric + safe punctuation. No spaces, no $`'"\;|&<>(){}[]
    # For complex values use /etc/certberus/config.env (sourced in root-only context).
    if [[ ! "$value" =~ ^[A-Za-z0-9_./:@+,=-]*$ ]]; then
        cb_die "--set value contains disallowed characters (allowed: alnum _./:@+,=-): $value"
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
}

# -------- Requirements --------
cb_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        cb_die "Script must be run as root (sudo)."
    fi
}

cb_require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        cb_die "Missing commands: ${missing[*]}"
    fi
}

# -------- Snapshots --------
# cb_snapshot "/etc/apache2" "apache2-pre-md" [extra_src ...]
# Returns path to tar.gz on stdout + into CB_LAST_SNAPSHOT.
# Atomic: tar -> tmp -> rename, so a partial tar never has the final name.
# With multiple sources, all existing ones are archived (missing ones are skipped with a warning).
cb_snapshot() {
    local src="$1" tag="${2:-generic}"
    shift 2 2>/dev/null || true
    local extras=("$@") ts dest tmp
    ts="$(date +%Y%m%d-%H%M%S-%N)-$$"
    mkdir -p "$CB_BACKUP_DIR" 2>/dev/null || { cb_warn "Cannot create $CB_BACKUP_DIR"; return 1; }
    dest="$CB_BACKUP_DIR/${tag}-${ts}.tar.gz"
    if [[ ! -e "$src" ]]; then
        cb_warn "Snapshot source does not exist: $src"
        return 1
    fi
    # Collect all existing sources (relative to /)
    local -a sources=("${src#/}")
    local e
    for e in "${extras[@]}"; do
        [[ -z "$e" ]] && continue
        if [[ -e "$e" ]]; then
            sources+=("${e#/}")
        else
            cb_log "Snapshot: skipping (does not exist) $e"
        fi
    done
    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] Snapshot [${sources[*]}] -> $dest"
        CB_LAST_SNAPSHOT="$dest"
        printf '%s' "$dest"
        return 0
    fi
    tmp="${dest}.partial"
    local tar_err; tar_err=$(mktemp 2>/dev/null || mktemp -t cb-tar-err.XXXXXX 2>/dev/null || echo "/dev/null")
    # Trap for signal-based cleanup of .partial file on SIGTERM/SIGINT
    local _cb_snap_cleanup="rm -f \"$tmp\" \"$tar_err\" 2>/dev/null"
    trap "$_cb_snap_cleanup; trap - INT TERM HUP" INT TERM HUP
    if tar -czf "$tmp" -C / "${sources[@]}" 2>"$tar_err" && mv -f "$tmp" "$dest" 2>>"$tar_err"; then
        trap - INT TERM HUP
        cb_ok "Snapshot: $dest (${#sources[@]} source(s))"
        CB_LAST_SNAPSHOT="$dest"
        rm -f "$tar_err" 2>/dev/null
        printf '%s' "$dest"
        return 0
    else
        trap - INT TERM HUP
        rm -f "$tmp" 2>/dev/null
        local err_msg=""
        [[ -s "$tar_err" ]] && err_msg=" ($(head -3 "$tar_err" | tr '\n' '; '))"
        rm -f "$tar_err" 2>/dev/null
        cb_error "Snapshot failed: ${sources[*]}${err_msg}"
        return 1
    fi
}

cb_rollback_hint() {
    [[ -n "${CB_LAST_SNAPSHOT:-}" ]] || return 0
    cb_warn "Rollback:  tar -xzf $CB_LAST_SNAPSHOT -C /"
}

# cb_snapshot_restore [SNAPSHOT_FILE]
# Restores the last snapshot (or a specified one). Safely idempotent.
cb_snapshot_restore() {
    local snap="${1:-${CB_LAST_SNAPSHOT:-}}"
    if [[ -z "$snap" || ! -f "$snap" ]]; then
        cb_error "Rollback: snapshot not found"
        return 1
    fi
    if [[ "$CB_DRY_RUN" == "1" ]]; then
        cb_log "[DRY-RUN] tar -xzf $snap -C /"
        return 0
    fi
    if tar -xzf "$snap" -C / 2>&1 | tee -a "$CB_LOG_FILE"; then
        cb_ok "Snapshot restored: $snap"
        return 0
    fi
    cb_error "Rollback failed"
    return 1
}

# Auto-rollback: if we took a snapshot and the current state is broken,
# restore it. Used in ERR traps.
# Requires CB_AUTO_ROLLBACK=1 (default for safety: off in scripts, set in advanced.env).
cb_auto_rollback() {
    [[ "${CB_AUTO_ROLLBACK:-0}" == "1" ]] || { cb_rollback_hint; return 0; }
    [[ -n "${CB_LAST_SNAPSHOT:-}" ]] || { cb_warn "Auto-rollback: no snapshot"; return 1; }
    cb_warn "AUTO-ROLLBACK active, restoring: $CB_LAST_SNAPSHOT"
    cb_snapshot_restore "$CB_LAST_SNAPSHOT"
}

# -------- Load config files --------
cb_load_config() {
    local f line key val
    for f in "$CB_ADVANCED_FILE" "$CB_CONFIG_FILE"; do
        [[ -r "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            if [[ "$line" =~ ^[[:space:]]*(CB_[A-Za-z0-9_]+)=(.*) ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                val="${val#\"}" ; val="${val%\"}"
                val="${val#\'}" ; val="${val%\'}"
                export "$key=$val"
            fi
        done < "$f"
        cb_debug "Loaded: $f"
    done
    cb_sanitize_acme_url
}

# -------- Self-bootstrap of /etc/certberus/ + hooks layout --------
# Called from bin/certberus after cb_load_config, idempotent.
# Key for bundle - without install.sh /etc/certberus would not exist and
# the mod_md adapter (/opt/certberus/mod_md-adapter.sh) could not find hooks.
# Skipped for non-root (read-only smoke test, --help, version).
# Creates skeleton even if parts exist - only adds missing directories.
cb_ensure_runtime_dirs() {
    [[ "$(id -u 2>/dev/null)" == "0" ]] || return 0
    local d
    # Main directories (logs/state/backups - common.sh creates them on first log anyway, but let's have them ready)
    for d in "$CB_PREFIX" "$CB_HOOKS_DIR" "$CB_LOG_DIR" "$CB_STATE_DIR" "$CB_BACKUP_DIR"; do
        [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || cb_debug "Cannot create $d"
    done
    # Hook event directories. mod_md emits: renewing, renewed, installed, errored,
    # ocsp-errored, ocsp-renewed. Certberus choices: pre-issue, post-issue, post-reload,
    # on-failure (cb_run_hooks). We create both sets so they are ready immediately.
    local ev
    for ev in pre-issue post-issue post-reload post-renew renewing renewed installed errored \
              ocsp-renewed ocsp-errored on-failure deploy; do
        d="$CB_HOOKS_DIR/${ev}.d"
        [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null
    done
    # README in hooks directory (on first install)
    if [[ ! -f "$CB_HOOKS_DIR/README" ]]; then
        cat > "$CB_HOOKS_DIR/README" 2>/dev/null <<'EOF'
certberus hooks
===============
Executable scripts (chmod +x) in <event>.d/ are called on the given event
(similar to run-parts). Files with .example, .bak, .disabled extensions are ignored.

Environment variables in hook scripts:
  CA_EVENT             event name (renewed, installed, errored, ...)
  CA_PRIMARY_DOMAIN    primary domain
  CA_DOMAIN_LIST       full list of domains (space-separated)
  CA_WEBSERVER         apache | nginx | tomcat
  CA_SOURCE            mod_md | certbot | certberus

Per-hook timeout is CB_HOOK_TIMEOUT (default 60s).

Example: reload HAProxy after renewal
  cat > post-reload.d/30-reload-haproxy.sh <<'SH'
  #!/bin/bash
  systemctl reload haproxy
  SH
  chmod +x post-reload.d/30-reload-haproxy.sh
EOF
    fi
    # Permissions (config.env may contain HMAC secret - 0600 root-only)
    [[ -f "$CB_CONFIG_FILE" ]] && chmod 0600 "$CB_CONFIG_FILE" 2>/dev/null
    [[ -f "$CB_ADVANCED_FILE" ]] && chmod 0600 "$CB_ADVANCED_FILE" 2>/dev/null
    # /etc/certberus + /etc/certberus/hooks must be traversable by www-data,
    # otherwise the Apache mod_md MDMessageCMD adapter (running as www-data) cannot
    # execute /etc/certberus/hooks/<event>.d/*. Secret files inside have 0600.
    chmod 0755 "$CB_PREFIX" 2>/dev/null
    chmod 0755 "$CB_HOOKS_DIR" 2>/dev/null
    for ev in pre-issue post-issue post-reload post-renew renewing renewed installed errored \
              ocsp-renewed ocsp-errored on-failure deploy; do
        chmod 0755 "$CB_HOOKS_DIR/${ev}.d" 2>/dev/null
    done
    return 0
}

# Persists --email / --domain / --ca for the next run into config.env.
# Called on successful cmd_auto when admin did not provide config (typically bundle).
# Never overwrites existing values - only fills in missing keys.
cb_persist_config_skeleton() {
    if [[ "$(id -u 2>/dev/null)" != "0" ]]; then
        cb_warn "Saving config.env requires root. Run as root (sudo)."
        return 1
    fi
    [[ -f "$CB_CONFIG_FILE" ]] && return 0  # already exists, do not overwrite
    local email="${1:-}" domains="${2:-}" ca="${3:-letsencrypt}"
    local eab_kid="${4:-}" eab_hmac="${5:-}" acme_url="${6:-}"
    [[ -z "$email" ]] && return 0  # no email means nothing to write
    mkdir -p "$(dirname "$CB_CONFIG_FILE")" 2>/dev/null || return 0
    umask 077
    {
        printf '# /etc/certberus/config.env - auto-generated %s\n' "$(date '+%F %T')"
        printf '# These values are used by '\''certberus auto'\'' (cron, systemd timer).\n\n'
        printf 'CB_EMAIL="%s"\n' "$email"
        printf 'CB_DOMAINS="%s"\n' "$domains"
        printf 'CB_CA="%s"\n' "$ca"
        echo
        printf '# CB_WEBSERVER=auto       # auto | apache | nginx | tomcat\n'
        printf '# CB_STAGING=0            # 1 = LE staging (testing)\n'
        printf '# CB_AUTO_ROLLBACK=1      # 1 = on failure, restore Apache config snapshot\n'
        echo
        if [[ -n "$eab_kid" ]]; then
            printf 'CB_EAB_KID="%s"\n' "$eab_kid"
            printf 'CB_EAB_HMAC="%s"\n' "$eab_hmac"
            [[ -n "$acme_url" ]] && printf 'CB_ACME_URL="%s"\n' "$acme_url"
        else
            printf '# HARICA / ZeroSSL EAB:\n'
            printf '# CB_EAB_KID=""\n'
            printf '# CB_EAB_HMAC=""\n'
            printf '# CB_ACME_URL=""          # HARICA: https://acme.harica.gr/<UUID>/directory\n'
        fi
    } > "$CB_CONFIG_FILE"
    chmod 0600 "$CB_CONFIG_FILE" 2>/dev/null
    cb_ok "Generated $CB_CONFIG_FILE (mod 0600)"
    cb_log "  Next 'certberus auto' no longer needs --email/--domain."
}

# Guard against a common mistake: admin left a placeholder HARICA URL
# in config.env but CB_CA=letsencrypt. Without this guard, certberus sent
# LE calls to the HARICA endpoint and certbot failed with "requires EAB".
# Uses a guard to prevent duplicate warnings across parent/child loading.
cb_sanitize_acme_url() {
    local url="${CB_ACME_URL:-}"
    if [[ -z "$url" ]]; then
        return 0
    fi
    # Placeholder (e.g. '.../acme/..../directory') -> discard.
    # Deduplicate warning for same value across parent/child processes (export).
    if [[ "$url" == *".../"* || "$url" == *"VAS_UUID"* || "$url" == *"YOUR_UUID"* ]]; then
        if [[ "${_CB_ACME_URL_WARNED:-}" != "$url" ]]; then
            cb_warn "CB_ACME_URL contains a placeholder ($url), discarding."
            _CB_ACME_URL_WARNED="$url"
            export _CB_ACME_URL_WARNED
        fi
        CB_ACME_URL=""
        export CB_ACME_URL
        return 0
    fi
    # CA / URL mismatch: if LE but URL points elsewhere, discard and use default.
    case "${CB_CA:-letsencrypt}" in
        letsencrypt)
            if [[ "$url" != *"letsencrypt.org"* ]]; then
                cb_warn "CB_CA=letsencrypt, but CB_ACME_URL is not letsencrypt.org ($url). Discarding CB_ACME_URL."
                CB_ACME_URL=""
            fi
            ;;
        harica)
            if [[ "$url" != *"harica.gr"* ]]; then
                cb_warn "CB_CA=harica, but CB_ACME_URL is not harica.gr ($url). Discarding CB_ACME_URL."
                CB_ACME_URL=""
            fi
            ;;
        zerossl)
            if [[ "$url" != *"zerossl.com"* ]]; then
                cb_warn "CB_CA=zerossl, but CB_ACME_URL is not zerossl.com ($url). Discarding CB_ACME_URL."
                CB_ACME_URL=""
            fi
            ;;
    esac
    export CB_ACME_URL
}

# -------- Retry wrapper --------
# cb_retry 3 5 some_command args...   (attempts, delay)
# NOTE: classic gotcha - after `if foo; then ...; fi` bash sets $?=0
# even if foo failed and there was no else branch. So we capture rc before if.
cb_retry() {
    local tries="$1" delay="$2"; shift 2
    local i=0 rc=0
    while (( i < tries )); do
        "$@"
        rc=$?
        if (( rc == 0 )); then
            return 0
        fi
        ((i++)) || true
        if (( i < tries )); then
            cb_debug "Attempt $i/$tries failed (rc=$rc), waiting ${delay}s..."
            sleep "$delay"
        fi
    done
    return "$rc"
}

# -------- certbot wrapper with output verification --------
# NOTE: certbot 4.x returns exit 0 even when validation challenge failed
# ("Some challenges have failed"). So we must verify the actual output.
#
# Usage:   cb_certbot_issue <domain> [certbot args...]
# Returns 0 if /etc/letsencrypt/live/<domain>/fullchain.pem exists
#   and was modified during this invocation (mtime >= before call).
cb_certbot_issue() {
    local domain="$1"; shift
    local live="/etc/letsencrypt/live/$domain/fullchain.pem"
    local before_ts=0 after_ts=0
    [[ -f "$live" ]] && before_ts=$(stat -c %Y "$live" 2>/dev/null || echo 0)
    local start_epoch; start_epoch=$(date +%s)
    local out rc
    # Capture stdout and stderr for later analysis, but also let them flow
    out=$(certbot "$@" 2>&1) ; rc=$?
    printf '%s\n' "$out"
    # If exit rc != 0 -> failure
    if (( rc != 0 )); then
        return "$rc"
    fi
    # Dry-run does not create files - exit 0 from certbot is sufficient.
    if [[ "${CB_DRY_RUN:-0}" == "1" ]] || printf '%s\n' "$out" | grep -qi "dry run"; then
        return 0
    fi
    # Exit 0 does not yet mean success (certbot 4.x bug). Verify cert file.
    if [[ ! -f "$live" ]]; then
        cb_error "certbot returned 0, but $live does not exist"
        if printf '%s' "$out" | grep -qE "Some challenges have failed|Unable to register|Domain .* failed"; then
            return 2
        fi
        return 3
    fi
    after_ts=$(stat -c %Y "$live" 2>/dev/null || echo 0)
    # If cert was not updated during this invocation, it was already current (OK).
    # "Certificate not yet due for renewal" is a valid case for renew.
    if (( after_ts < start_epoch )) && ! printf '%s' "$out" | grep -qE "not yet due for renewal|Certificate not yet due"; then
        cb_warn "Cert $domain is not fresh (mtime $after_ts < start $start_epoch)"
    fi
    return 0
}

# -------- Trap/cleanup --------
CB_CLEANUP_FNS=()
cb_on_exit_register() { CB_CLEANUP_FNS+=("$1"); }
_cb_run_cleanup() {
    local rc=$?
    local fn
    for fn in "${CB_CLEANUP_FNS[@]}"; do
        "$fn" "$rc" 2>/dev/null || true
    done
    exit "$rc"
}
cb_setup_traps() {
    trap _cb_run_cleanup EXIT INT TERM
}

# -------- Existing installation detection --------
cb_mark_installed() {
    local component="$1"
    mkdir -p "$CB_STATE_DIR/installed" 2>/dev/null || return 1
    date +%s > "$CB_STATE_DIR/installed/${component}.marker"
}
cb_is_installed() {
    [[ -f "$CB_STATE_DIR/installed/$1.marker" ]]
}

# -------- Service management with fallback --------
# Usage: cb_svc_reload nginx | cb_svc_restart tomcat10 | cb_svc_is_active nginx
# Ensures operation even when systemctl is not available (docker/non-systemd).
_cb_has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}
cb_svc_reload() {
    local svc="$1"
    if _cb_has_systemd; then
        systemctl reload "$svc"
    elif command -v service >/dev/null 2>&1; then
        service "$svc" reload
    elif [[ "$svc" == nginx* ]] && command -v nginx >/dev/null 2>&1; then
        nginx -s reload
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" reload
    else
        cb_warn "Cannot reload $svc (no systemctl/service/init.d)"
        return 1
    fi
}
cb_svc_restart() {
    local svc="$1"
    if _cb_has_systemd; then
        systemctl restart "$svc"
    elif command -v service >/dev/null 2>&1; then
        service "$svc" restart
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" restart
    else
        cb_warn "Cannot restart $svc"
        return 1
    fi
}
cb_svc_is_active() {
    local svc="$1"
    if _cb_has_systemd; then
        systemctl is-active --quiet "$svc"
    elif command -v service >/dev/null 2>&1; then
        service "$svc" status >/dev/null 2>&1
    elif [[ "$svc" == nginx* ]]; then
        pgrep -x nginx >/dev/null 2>&1
    else
        return 0   # unknown, assume OK
    fi
}
cb_svc_start() {
    local svc="$1"
    if _cb_has_systemd; then
        systemctl start "$svc"
    elif command -v service >/dev/null 2>&1; then
        service "$svc" start
    elif [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" start
    else
        return 1
    fi
}
