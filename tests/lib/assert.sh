#!/bin/bash
# tests/lib/assert.sh - shared assertion helpers + reporting
# Usage:
#   source "$(dirname "$0")/../lib/assert.sh"     (z tests/unit/, tests/chaos/, ...)
#   source "$(dirname "$0")/lib/assert.sh"        (z tests/)

# Idempotentni source
[[ -n "${_CB_TEST_LIB_LOADED:-}" ]] && return 0
_CB_TEST_LIB_LOADED=1

: "${CB_TEST_PASS:=0}"
: "${CB_TEST_FAIL:=0}"
: "${CB_TEST_SKIP:=0}"
: "${CB_TEST_NAME:=$(basename "${BASH_SOURCE[1]:-$0}" .sh)}"

# Color only when stdout is a TTY and CB_COLOR is not 'never'
if [[ -t 1 && "${CB_COLOR:-auto}" != "never" ]]; then
    _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_BLU=$'\033[34m'; _C_BLD=$'\033[1m'; _C_RST=$'\033[0m'
else
    _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_BLD=""; _C_RST=""
fi

t_pass() { CB_TEST_PASS=$((CB_TEST_PASS+1)); printf "  ${_C_GRN}PASS${_C_RST} %s\n" "$1"; }
t_fail() {
    CB_TEST_FAIL=$((CB_TEST_FAIL+1))
    printf "  ${_C_RED}FAIL${_C_RST} %s\n" "$1" >&2
    [[ -n "${2:-}" ]] && printf "       %s\n" "$2" >&2
}
t_skip() { CB_TEST_SKIP=$((CB_TEST_SKIP+1)); printf "  ${_C_YEL}SKIP${_C_RST} %s\n" "$1"; }
t_info() { printf "  -- %s\n" "$1"; }

# assert_eq EXPECTED ACTUAL [MESSAGE]
assert_eq() {
    if [[ "$1" == "$2" ]]; then t_pass "${3:-eq}"
    else t_fail "${3:-eq}" "expected: $(printf %q "$1") | got: $(printf %q "$2")"
    fi
}

assert_ne() {
    if [[ "$1" != "$2" ]]; then t_pass "${3:-ne}"
    else t_fail "${3:-ne}" "both: $(printf %q "$1")"
    fi
}

# assert_contains HAYSTACK NEEDLE [MESSAGE]
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then t_pass "${3:-contains}"
    else t_fail "${3:-contains}" "needle: $(printf %q "$2") not in haystack (${#1}b)"
    fi
}

assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then t_pass "${3:-not_contains}"
    else t_fail "${3:-not_contains}" "needle: $(printf %q "$2") was found"
    fi
}

# assert_match HAYSTACK REGEX [MESSAGE]
assert_match() {
    if [[ "$1" =~ $2 ]]; then t_pass "${3:-match}"
    else t_fail "${3:-match}" "regex: $2"
    fi
}

assert_file_exists() {
    if [[ -e "$1" ]]; then t_pass "${2:-file: $1}"
    else t_fail "${2:-file: $1}" "missing: $1"
    fi
}

assert_dir_exists() {
    if [[ -d "$1" ]]; then t_pass "${2:-dir: $1}"
    else t_fail "${2:-dir: $1}" "missing dir: $1"
    fi
}

assert_exit_code() {
    if [[ "$1" == "$2" ]]; then t_pass "${3:-exit code} ($2)"
    else t_fail "${3:-exit code}" "expected: $1 | got: $2"
    fi
}

# t_summary - print summary and exit with 0/1
t_summary() {
    echo
    if (( CB_TEST_FAIL == 0 )); then
        printf "${_C_GRN}[%s] OK${_C_RST}  pass=%d fail=%d skip=%d\n" \
            "$CB_TEST_NAME" "$CB_TEST_PASS" "$CB_TEST_FAIL" "$CB_TEST_SKIP"
        exit 0
    else
        printf "${_C_RED}[%s] FAIL${_C_RST} pass=%d fail=%d skip=%d\n" \
            "$CB_TEST_NAME" "$CB_TEST_PASS" "$CB_TEST_FAIL" "$CB_TEST_SKIP"
        exit 1
    fi
}

# Resolve repo root (parent of tests/)
CB_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CB_REPO_ROOT
