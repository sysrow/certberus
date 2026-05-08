#!/bin/bash
# certberus/lib/hooks.sh
# Run-parts wrapper for lifecycle events + adapter for mod_md MDMessageCMD.
[[ -n "${_CB_HOOKS_LOADED:-}" ]] && return 0
_CB_HOOKS_LOADED=1

# Known events (for validation):
#   pre-install   post-install
#   pre-snapshot  post-snapshot
#   pre-issue     post-issue
#   pre-deploy    post-deploy
#   pre-reload    post-reload
#   on-failure    on-rollback
# + mod_md-specific (proxy z MDMessageCMD):
#   renewing   renewed   installed   expiring   errored
#   ocsp-renewed   ocsp-errored
#   challenge-setup
CB_KNOWN_EVENTS=(
    pre-install post-install
    pre-snapshot post-snapshot
    pre-issue post-issue
    pre-deploy post-deploy
    pre-reload post-reload
    post-renew
    on-failure on-rollback
    renewing renewed installed expiring errored
    ocsp-renewed ocsp-errored challenge-setup
)

# cb_run_hooks EVENT
# Uses run-parts if available (Debian), otherwise manual loop (RHEL).
# CA_* variables are exported (if the caller has set them).
cb_run_hooks() {
    local event="$1"
    local dir="${CB_HOOKS_DIR}/${event}.d"

    [[ -d "$dir" ]] || return 0

    # Export context
    export CA_EVENT="$event"
    export CA_WEBSERVER="${CA_WEBSERVER:-}"
    export CA_DOMAIN_LIST="${CA_DOMAIN_LIST:-}"
    export CA_PRIMARY_DOMAIN="${CA_PRIMARY_DOMAIN:-}"
    export CA_CERT_PATH="${CA_CERT_PATH:-}"
    export CA_KEY_PATH="${CA_KEY_PATH:-}"
    export CA_CERT_ISSUER="${CA_CERT_ISSUER:-}"
    export CA_STAGING="${CB_STAGING:-0}"
    export CA_DRY_RUN="${CB_DRY_RUN:-0}"
    export CA_LOG_FILE="${CB_LOG_FILE:-}"
    export CA_SNAPSHOT_PATH="${CB_LAST_SNAPSHOT:-}"

    local count=0 failed=0 f rc
    local to="${CB_HOOK_TIMEOUT:-60}"
    local have_timeout=0
    command -v timeout >/dev/null 2>&1 && have_timeout=1

    local prev_nullglob
    prev_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$dir"/*; do
        [[ -x "$f" ]] || continue
        [[ "$f" == *.example || "$f" == *.bak || "$f" == *.disabled ]] && continue
        ((count++))
        cb_debug "Hook: $f (timeout=${to}s)"
        if (( have_timeout )); then
            timeout "$to" "$f"; rc=$?
        else
            "$f"; rc=$?
        fi
        if (( rc != 0 )); then
            if (( rc == 124 )); then
                cb_error "Hook timeout (>${to}s): $f"
            else
                cb_warn "Hook failed (rc=$rc): $f"
            fi
            failed=1
            if [[ "$event" == pre-* ]]; then
                eval "$prev_nullglob"
                return "$rc"
            fi
        fi
    done
    eval "$prev_nullglob"

    (( failed == 0 )) && return 0 || return 1
}

# Helper for webserver modules - set context.
# cb_hook_context WEBSERVER DOMAINS... (first is primary)
cb_hook_context() {
    CA_WEBSERVER="$1"; shift
    CA_PRIMARY_DOMAIN="${1:-}"
    CA_DOMAIN_LIST="$*"
    export CA_WEBSERVER CA_PRIMARY_DOMAIN CA_DOMAIN_LIST
}

cb_hook_set_cert() {
    CA_CERT_PATH="$1"
    CA_KEY_PATH="$2"
    CA_CERT_ISSUER="${3:-}"
    export CA_CERT_PATH CA_KEY_PATH CA_CERT_ISSUER
}

# -------- mod_md adapter --------
# This is the script installed as MDMessageCMD.
# It receives: <event> <domain>
# We just forward it to cb_run_hooks with the correct CA_* variables.
#
# Used from webservers/apache-md*.sh when generating hook scripts.
cb_mod_md_adapter_body() {
    cat <<'EOF'
#!/bin/bash
# Certberus mod_md MDMessageCMD adapter - generated, do not edit.
# Forwards events from Apache mod_md to /etc/certberus/hooks/<event>.d/
set -u
EVENT="${1:-unknown}"
DOMAIN="${2:-}"

# Sanitization: EVENT must be only [a-z0-9-], DOMAIN must be only FQDN chars.
# Apache mod_md events are a known list, but defense is defense - we do not want
# a future (or modified) version of mod_md to send "../foo" as an event.
case "$EVENT" in
    pre-issue|post-issue|post-reload|renewing|renewed|installed|errored|\
    expiring|ocsp-renewed|ocsp-errored|challenge-setup|challenge-cleanup|\
    on-failure|deploy|unknown) ;;
    *)
        logger -t certberus-md -p daemon.warn -- "rejected unknown event=$EVENT" 2>/dev/null || true
        exit 0
        ;;
esac
# DOMAIN: allow fqdn / wildcard / empty
if [[ -n "$DOMAIN" ]] && ! [[ "$DOMAIN" =~ ^(\*\.)?[A-Za-z0-9._-]+$ ]]; then
    logger -t certberus-md -p daemon.warn -- "rejected unsafe domain=$DOMAIN" 2>/dev/null || true
    exit 0
fi

export CA_EVENT="$EVENT"
export CA_WEBSERVER="apache"
export CA_PRIMARY_DOMAIN="$DOMAIN"
export CA_DOMAIN_LIST="$DOMAIN"
export CA_SOURCE="mod_md"

LOG="/var/log/certberus/mod_md-events.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
# Fallback for inaccessible log (non-root, fresh install)
[[ -w "$(dirname "$LOG")" ]] || LOG="/dev/null"
{
    echo "[$(date '+%F %T')] event=$EVENT domain=$DOMAIN"
} >> "$LOG" 2>/dev/null

# Syslog
command -v logger >/dev/null 2>&1 && \
    logger -t certberus-md -p daemon.info -- "mod_md event=$EVENT domain=$DOMAIN"

# Run hooks with per-hook timeout (CB_HOOK_TIMEOUT, default 60s).
HOOKS_DIR="/etc/certberus/hooks"
D="$HOOKS_DIR/${EVENT}.d"
HOOK_TO="${CB_HOOK_TIMEOUT:-60}"
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
if [[ -d "$D" ]]; then
    for f in "$D"/*; do
        [[ -x "$f" ]] || continue
        case "$f" in *.example|*.bak|*.disabled) continue ;; esac
        if (( HAVE_TIMEOUT )); then
            timeout "$HOOK_TO" "$f" >> "$LOG" 2>&1 || true
        else
            "$f" >> "$LOG" 2>&1 || true
        fi
    done
fi

# Auto-graceful Apache on renewed/installed - without this, Apache would not
# start using a cert issued in the background until the next 'systemctl reload apache2'.
# Sudoers (/etc/sudoers.d/certberus_mod_md) allows 'apache2ctl graceful'
# for www-data without a password. Disableable via CB_MOD_MD_AUTO_RELOAD=0.
case "$EVENT" in
    renewed|installed)
        if [[ "${CB_MOD_MD_AUTO_RELOAD:-1}" == "1" ]]; then
            APCH=""
            for c in /usr/sbin/apache2ctl /usr/sbin/apachectl /usr/local/sbin/apache2ctl; do
                [[ -x "$c" ]] && { APCH="$c"; break; }
            done
            if [[ -n "$APCH" ]]; then
                if [[ "$(id -u)" == "0" ]]; then
                    "$APCH" graceful >>"$LOG" 2>&1 || true
                elif command -v sudo >/dev/null 2>&1; then
                    sudo -n "$APCH" graceful >>"$LOG" 2>&1 || true
                fi
            fi
        fi
        ;;
esac

exit 0
EOF
}
