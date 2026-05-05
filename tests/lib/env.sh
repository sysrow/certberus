#!/bin/bash
# tests/lib/env.sh - sandbox and temp helpers
# Handles:
#   1. exec-capable temp (CI runtimes often mount /tmp as noexec)
#   2. isolated CB_PREFIX tree (config, logs, hooks, state)
#   3. cleanup via trap
#
# Usage:
#   source "$(dirname "$0")/../lib/env.sh"
#   SANDBOX=$(t_mktempdir)
#   trap 't_cleanup' EXIT
#   t_isolate_cb_dirs "$SANDBOX"

[[ -n "${_CB_TEST_ENV_LOADED:-}" ]] && return 0
_CB_TEST_ENV_LOADED=1

# Finds a tempdir that IS executable (run-parts, hooks...).
# CI/sandboxed runtimes often mount /tmp as noexec. We try in order:
#   $CB_TEST_TMPDIR (override), /var/tmp, $HOME/.cache/cb-tests, /dev/shm, /tmp
t_mktempdir() {
    local prefix="${1:-cb-test}"
    local cand
    for cand in "${CB_TEST_TMPDIR:-}" /var/tmp "$HOME/.cache/cb-tests" /dev/shm /tmp; do
        [[ -z "$cand" ]] && continue
        [[ -d "$cand" ]] || mkdir -p "$cand" 2>/dev/null || continue
        [[ -w "$cand" ]] || continue
        local d
        d=$(mktemp -d "$cand/${prefix}.XXXXXX" 2>/dev/null) || continue
        # Probe exec
        echo '#!/bin/sh
echo ok' > "$d/.probe"
        chmod +x "$d/.probe" 2>/dev/null
        if [[ "$("$d/.probe" 2>/dev/null)" == "ok" ]]; then
            rm -f "$d/.probe"
            _CB_TEST_TMPDIRS+=("$d")
            printf '%s' "$d"
            return 0
        fi
        rm -rf "$d"
    done
    echo "t_mktempdir: could not find an exec-capable tempdir" >&2
    return 1
}

declare -a _CB_TEST_TMPDIRS=()

t_cleanup() {
    local d
    for d in "${_CB_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}

# Set up an isolated CB_PREFIX tree inside SANDBOX. Everything goes outside /etc.
# Usage:
#   t_isolate_cb_dirs "$SANDBOX"
#   # now: $CB_PREFIX, $CB_HOOKS_DIR, $CB_LOG_DIR, $CB_STATE_DIR, $CB_BACKUP_DIR
t_isolate_cb_dirs() {
    local root="$1"
    export CB_PREFIX="$root/etc"
    export CB_HOOKS_DIR="$root/etc/hooks"
    export CB_LOG_DIR="$root/log"
    export CB_STATE_DIR="$root/lib"
    export CB_BACKUP_DIR="$root/backup"
    export CB_CONFIG_FILE="$root/etc/config.env"
    export CB_ADVANCED_FILE="$root/etc/advanced.env"
    export CB_LOG_FILE="$root/log/cb.log"
    export CB_LOCK_FILE="$root/cb.lock"
    export CB_SYSLOG_ENABLED=0
    export CB_COLOR=never
    mkdir -p "$CB_PREFIX" "$CB_HOOKS_DIR" "$CB_LOG_DIR" "$CB_STATE_DIR" "$CB_BACKUP_DIR"
}

# Prepend MOCK PATH to $PATH - mocks are shell scripts in this directory.
t_prepend_mock_path() {
    local mock="$1"
    [[ -d "$mock" ]] || mkdir -p "$mock"
    export PATH="$mock:$PATH"
}

# Mocks the contextual log helpers from lib/common.sh (for tests that source only parts).
t_stub_log_helpers() {
    cb_die()   { echo "DIE: $*" >&2; exit 99; }
    cb_log()   { :; }
    cb_warn()  { :; }
    cb_error() { :; }
    cb_debug() { :; }
    cb_ok()    { :; }
    cb_sep()   { :; }
    cb_banner(){ :; }
    : "${CB_VERBOSE:=0}"
    export CB_VERBOSE
}

# Skip test when a required tool is missing — return exit 0 without failure.
t_require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        t_skip "${CB_TEST_NAME}: $tool not available"
        t_summary
    fi
}

# Skip docker tests when docker is missing or not running.
t_require_docker() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        t_skip "${CB_TEST_NAME}: docker not available"
        t_summary
    fi
}
