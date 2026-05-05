#!/bin/bash
# tests/run-all.sh - master test runner for certberus
#
# Tiers (industry-standard):
#   unit/         pure bash, fast, no docker, no network. Always runs in CI.
#   chaos/        destructive scenarios (filesystem, network sandbox, security).
#                 Pure bash; some require 'unshare' or root.
#   integration/  Docker matrix (apache/nginx/tomcat across distributions).
#                 Requires running docker daemon.
#
# Options:
#   --unit             unit/ only
#   --chaos            chaos/ only (+ unit if nothing else specified)
#   --integration      integration/ only (Docker)
#   --quick            unit/ only (alias)
#   --no-docker        skip integration/
#   --only PATTERN     run only tests whose name contains PATTERN
#   --keep-going       continue even on failure
#   -v, --verbose      verbose output (set -x)
#
# Examples:
#   bash tests/run-all.sh                        # unit + chaos (no docker)
#   bash tests/run-all.sh --unit                 # fastest
#   bash tests/run-all.sh --integration          # Docker matrix
#   bash tests/run-all.sh --only firewall        # single test
#   bash tests/run-all.sh --unit --keep-going    # all unit even on failure

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

RUN_UNIT=0; RUN_CHAOS=0; RUN_INT=0
NO_DOCKER=0; ONLY=""; KEEPGOING=0; VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)         RUN_UNIT=1 ;;
        --chaos)        RUN_CHAOS=1 ;;
        --integration)  RUN_INT=1 ;;
        --quick)        RUN_UNIT=1 ;;
        --no-docker)    NO_DOCKER=1 ;;
        --only)         shift; ONLY="${1:-}" ;;
        --keep-going)   KEEPGOING=1 ;;
        -v|--verbose)   VERBOSE=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *)
            echo "Unknown flag: $1 (help: --help)" >&2; exit 2 ;;
    esac
    shift
done

# Default tier selection: if nothing chosen, run unit + chaos (chaos is
# pure-bash and relatively fast). Integration requires --integration.
if (( RUN_UNIT == 0 && RUN_CHAOS == 0 && RUN_INT == 0 )); then
    RUN_UNIT=1
    RUN_CHAOS=1
fi
(( NO_DOCKER == 1 )) && RUN_INT=0

declare -a BATCH=()
add_dir() {
    local dir="$1" t
    [[ -d "$dir" ]] || return 0
    while IFS= read -r t; do
        [[ -n "$ONLY" && "$t" != *"$ONLY"* ]] && continue
        BATCH+=("$t")
    done < <(ls "$dir"/test-*.sh 2>/dev/null | sort)
}

(( RUN_UNIT )) && add_dir "unit"
(( RUN_CHAOS )) && add_dir "chaos"
(( RUN_INT ))   && add_dir "integration"

if (( ${#BATCH[@]} == 0 )); then
    echo "No tests matching filter."
    exit 1
fi

start=$SECONDS
pass=0; fail=0; skip=0
declare -a FAILED=()

for t in "${BATCH[@]}"; do
    name="${t#./}"
    name="${name%.sh}"
    printf "${C_B}>> %s${C_0}\n" "$name"
    if (( VERBOSE )); then
        bash -x "$t"
    else
        bash "$t"
    fi
    rc=$?
    case "$rc" in
        0)   pass=$((pass+1)) ;;
        77)  skip=$((skip+1)); echo "  ${C_Y}(suite skipped)${C_0}" ;;
        *)   fail=$((fail+1)); FAILED+=("$name (rc=$rc)") ;;
    esac
    echo
    if (( fail > 0 && KEEPGOING == 0 )); then
        echo "${C_R}Stopping at first failure (use --keep-going to continue).${C_0}"
        break
    fi
done

elapsed=$((SECONDS - start))

echo "===================================="
total=${#BATCH[@]}
printf "${C_B}Summary${C_0}: %d tests ${C_G}%d pass${C_0} ${C_R}%d fail${C_0} ${C_Y}%d skip${C_0}  (%ds)\n" \
    "$total" "$pass" "$fail" "$skip" "$elapsed"

if (( fail > 0 )); then
    printf "${C_R}Failed:${C_0}\n"
    for n in "${FAILED[@]}"; do echo "  - $n"; done
    exit 1
fi

printf "${C_G}OK${C_0}\n"
exit 0
