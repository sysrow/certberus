#!/bin/bash
# tests/e2e/run-on-box.sh - run a single chaos scenario on a remote Debian box.
#
# Usage:
#   tests/e2e/run-on-box.sh <BOX> <SCENARIO_ID>
#   BOX         : deb12 | deb13
#   SCENARIO_ID : matches a file in tests/e2e/scenarios/<id>.sh (case-insensitive)
#
# Pipeline:
#   1. Build certberus .deb (or bundle) locally.
#   2. SSH to box, factory-reset state (box_reset).
#   3. Upload + install certberus .deb.
#   4. Source the scenario file. It must declare:
#        SCENARIO_ID, SCENARIO_NAME, SCENARIO_BOX_OK (e.g. "deb12 deb13"),
#        SCENARIO_FQDN_PATTERN (e.g. "s002.@{WILDCARD}" — @{WILDCARD} expands
#          to $CB_E2E_DEB12_WILDCARD / $CB_E2E_DEB13_WILDCARD at run time)
#        Functions: scenario_seed (run-on-box), scenario_install_args,
#                   scenario_post_verify (optional)
#   5. Apply seed state, run `certberus install` with the args, poll openssl
#      for the cert, run post-verify.
#   6. Emit pass/fail + diagnostics in tests/e2e/results/<box>-<id>.<status>.log.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# shellcheck disable=SC1091
source "$HERE/lib/box.sh"

BOX="${1:-}"
SCEN="${2:-}"
[[ -n "$BOX" && -n "$SCEN" ]] || { echo "Usage: $0 <deb12|deb13> <scenario_id>" >&2; exit 2; }

SCEN_FILE=""
for cand in "$HERE/scenarios/$SCEN.sh" "$HERE/scenarios/${SCEN,,}.sh"; do
    [[ -f "$cand" ]] && { SCEN_FILE="$cand"; break; }
done
[[ -n "$SCEN_FILE" ]] || { echo "Unknown scenario: $SCEN" >&2; exit 2; }

# shellcheck disable=SC1090
source "$SCEN_FILE"

# Validate the scenario applies to this box
applies=0
for ok in $SCENARIO_BOX_OK; do
    [[ "$ok" == "$BOX" ]] && { applies=1; break; }
done
if (( ! applies )); then
    echo "Scenario $SCENARIO_ID is not applicable to $BOX (SCENARIO_BOX_OK='$SCENARIO_BOX_OK') — skip"
    exit 77
fi

WILDCARD="${BOX_WILDCARD[$BOX]}"
FQDN="${SCENARIO_FQDN_PATTERN//@\{WILDCARD\}/$WILDCARD}"
export FQDN BOX

RESULTS="$REPO/tests/e2e/results"
mkdir -p "$RESULTS"
LOG="$RESULTS/${BOX}-${SCENARIO_ID,,}.log"
: >"$LOG"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

log "=== Scenario $SCENARIO_ID on $BOX ==="
log "Name: $SCENARIO_NAME"
log "FQDN: $FQDN"

# --- 1. Build (skip when matrix runner already built once) ---
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    log "Building certberus artifacts (.deb + bundle)…"
    bash "$HERE/build-bundle.sh" >>"$LOG" 2>&1 || { log "BUILD FAILED"; mv "$LOG" "${LOG%.log}.fail.log"; exit 1; }
fi
DEB=$(ls -t "$REPO"/dist/certberus_*_all.deb 2>/dev/null | head -1)
BUNDLE=$(ls -t "$REPO"/dist/certberus-*.bundle 2>/dev/null | head -1)
log "  .deb    : ${DEB:-<missing>}"
log "  bundle  : ${BUNDLE:-<missing>}"

# --- 2. Reset box ---
log "Resetting $BOX to clean Debian baseline…"
box_reset "$BOX" >>"$LOG" 2>&1 || { log "BOX RESET FAILED"; mv "$LOG" "${LOG%.log}.fail.log"; exit 1; }

# --- 3. Install certberus ---
if [[ -n "$DEB" ]]; then
    log "Installing $DEB on $BOX…"
    box_install_certberus_deb "$BOX" "$DEB" >>"$LOG" 2>&1 \
        || { log "CERTBERUS INSTALL (deb) FAILED"; mv "$LOG" "${LOG%.log}.fail.log"; exit 1; }
elif [[ -n "$BUNDLE" ]]; then
    log "Installing bundle on $BOX (no .deb available)…"
    box_scp "$BOX" "$BUNDLE" /usr/local/sbin/certberus >>"$LOG" 2>&1
    box_ssh "$BOX" 'chmod +x /usr/local/sbin/certberus && certberus --version' >>"$LOG" 2>&1
else
    log "No artifact built; cannot proceed"; mv "$LOG" "${LOG%.log}.fail.log"; exit 1
fi

# --- 4. Apply scenario seed state ---
log "Applying scenario seed state…"
# scenario_seed runs on the box; pass FQDN and BOX via env. The function body
# is expected to be a heredoc that ends up as a single SSH invocation.
if declare -F scenario_seed >/dev/null; then
    if ! scenario_seed >>"$LOG" 2>&1; then
        log "SEED FAILED"; box_dump_diagnostics "$BOX" "$FQDN" "$RESULTS"
        mv "$LOG" "${LOG%.log}.fail.log"; exit 1
    fi
fi

# --- 5. Build certberus invocation ---
ARGS_INSTALL=$(scenario_install_args)
log "Running: certberus install $ARGS_INSTALL"
if ! box_ssh "$BOX" "certberus install $ARGS_INSTALL </dev/null" >>"$LOG" 2>&1; then
    log "certberus install non-zero exit (mod_md issuance is async; we still poll for cert)"
fi

# --- 6. Verify cert via openssl ---
log "Waiting up to 240s for cert to be issued and visible from outside…"
if wait_for_cert "$FQDN" 240 >>"$LOG" 2>&1; then
    log "verify_cert: OK"
else
    log "verify_cert: TIMED OUT or wrong issuer"
    box_dump_diagnostics "$BOX" "$FQDN" "$RESULTS" >>"$LOG" 2>&1
    mv "$LOG" "${LOG%.log}.fail.log"
    exit 1
fi

# --- 7. Optional extra assertions ---
if declare -F scenario_post_verify >/dev/null; then
    if ! scenario_post_verify >>"$LOG" 2>&1; then
        log "post-verify FAILED"
        box_dump_diagnostics "$BOX" "$FQDN" "$RESULTS" >>"$LOG" 2>&1
        mv "$LOG" "${LOG%.log}.fail.log"
        exit 1
    fi
fi

log "=== PASS ==="
mv "$LOG" "${LOG%.log}.pass.log"
exit 0
