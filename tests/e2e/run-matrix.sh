#!/bin/bash
# tests/e2e/run-matrix.sh - drive every scenario in tests/e2e/scenarios/ across
# the box matrix in parallel (one worker per box, serial within a box because
# scenarios share apt/state).
#
# Usage:
#   tests/e2e/run-matrix.sh                  # run every scenario whose
#                                            # SCENARIOS_BOX_OK includes any of
#                                            # the active boxes
#   tests/e2e/run-matrix.sh c-01 c-02 n-01   # restrict to listed scenarios
#
# Output:
#   tests/e2e/results/<box>-<scen>.{pass,fail}.log         - per-run log
#   tests/e2e/results/<box>-<scen>.<fqdn>.diag.txt         - on failure
#   tests/e2e/results/MATRIX.md                            - final report
#   tests/e2e/results/matrix.tsv                           - machine-readable
#
# Exits 0 if every scenario passed, non-zero otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

# Active boxes — user pruned the 3rd, keep only these.
BOXES=(deb12 deb13)

# Discover scenarios.
mapfile -t ALL_SCEN < <(ls "$HERE"/scenarios/*.sh 2>/dev/null | xargs -n1 basename | sed 's/\.sh$//' | sort)

# Filter by CLI args if any were passed.
if (( $# > 0 )); then
    REQUESTED=("$@")
    SCENARIOS=()
    for s in "${REQUESTED[@]}"; do
        if [[ -f "$HERE/scenarios/${s}.sh" ]]; then
            SCENARIOS+=("$s")
        else
            echo "WARN: unknown scenario '$s' — skipping" >&2
        fi
    done
else
    SCENARIOS=("${ALL_SCEN[@]}")
fi

(( ${#SCENARIOS[@]} > 0 )) || { echo "No scenarios to run." >&2; exit 2; }

TSV="$RESULTS/matrix.tsv"
: >"$TSV"
echo -e "box\tscenario\tstatus\tduration_s\troot_cause" >>"$TSV"

# Reuse an already-built artefact if present and fresher than the source tree.
# Building inside docker is the slow part of the matrix; on a busy host with
# many other containers a second docker-deb run can stall for tens of minutes.
DEB=$(ls -t "$REPO"/dist/certberus_*_all.deb 2>/dev/null | head -1)
BUNDLE=$(ls -t "$REPO"/dist/certberus-*.bundle 2>/dev/null | head -1)
if [[ -z "$DEB" && -z "$BUNDLE" ]]; then
    echo "==> No pre-built artefact found, building once…"
    if ! bash "$HERE/build-bundle.sh" >"$RESULTS/_build.log" 2>&1; then
        echo "Pre-build FAILED; see $RESULTS/_build.log" >&2
        tail -30 "$RESULTS/_build.log" >&2
        exit 1
    fi
    DEB=$(ls -t "$REPO"/dist/certberus_*_all.deb 2>/dev/null | head -1)
    BUNDLE=$(ls -t "$REPO"/dist/certberus-*.bundle 2>/dev/null | head -1)
else
    echo "==> Reusing existing artefacts in $REPO/dist/"
fi
echo "    .deb    : ${DEB:-<none>}"
echo "    bundle  : ${BUNDLE:-<none>}"

# Worker: run all scenarios for one box, serially.
worker() {
    local box="$1"; shift
    local scenarios=("$@")
    local s status start dur fqdn cause line
    for s in "${scenarios[@]}"; do
        # cheap applicability check: peek the scenario file
        local applies=0
        # shellcheck disable=SC1090
        ( source "$HERE/scenarios/${s}.sh"; for ok in $SCENARIO_BOX_OK; do [[ "$ok" == "$box" ]] && exit 0; done; exit 1 ) && applies=1
        if (( ! applies )); then
            printf '%s\t%s\tSKIP\t0\tnot-applicable\n' "$box" "$s" >>"$TSV"
            continue
        fi
        start=$SECONDS
        if SKIP_BUILD=1 bash "$HERE/run-on-box.sh" "$box" "$s" >/dev/null 2>&1; then
            status=PASS
            cause=""
        else
            status=FAIL
            cause=$(classify_failure "$RESULTS/${box}-${s}.fail.log")
        fi
        dur=$((SECONDS - start))
        printf '%s\t%s\t%s\t%d\t%s\n' "$box" "$s" "$status" "$dur" "$cause" >>"$TSV"
    done
}

# Classify failure root cause from the log. Heuristic — useful for triage.
classify_failure() {
    local log="$1"
    [[ -f "$log" ]] || { echo "no-log"; return; }
    # order matters — more specific first
    if grep -q "BOX RESET FAILED" "$log"; then echo "box-reset-failed"; return; fi
    if grep -q "BUILD FAILED" "$log"; then echo "build-failed"; return; fi
    if grep -q "CERTBERUS INSTALL (deb) FAILED" "$log"; then echo "cb-install-failed"; return; fi
    if grep -q "SEED FAILED" "$log"; then echo "seed-failed"; return; fi
    if grep -qE "urn:ietf:params:acme:error:rateLimited" "$log"; then echo "le-rate-limited"; return; fi
    if grep -qE "(answer to challenge invalid|unauthorized|connection refused)" "$log"; then echo "challenge-failed"; return; fi
    if grep -qE "no installation candidate" "$log"; then echo "apt-missing-pkg"; return; fi
    if grep -q "is masked" "$log"; then echo "systemd-masked"; return; fi
    if grep -q "Syntax error" "$log"; then echo "apache-syntax"; return; fi
    if grep -q "post-verify FAILED" "$log"; then echo "post-verify"; return; fi
    if grep -q "TIMED OUT or wrong issuer" "$log"; then
        if grep -q "does not point to this server" "$log"; then echo "dns-mismatch"; return; fi
        echo "cert-timeout"
        return
    fi
    echo "other"
}
export -f classify_failure

# Launch one worker per box in parallel.
pids=()
for box in "${BOXES[@]}"; do
    worker "$box" "${SCENARIOS[@]}" &
    pids+=($!)
done

# Wait for all workers.
exit_code=0
for pid in "${pids[@]}"; do
    wait "$pid" || exit_code=1
done

# Build markdown report.
report() {
    local md="$RESULTS/MATRIX.md"
    {
        echo "# Certberus chaos matrix — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "Boxes: ${BOXES[*]}  |  Scenarios run: ${#SCENARIOS[@]}"
        echo
        local total=0 pass=0 fail=0 skip=0
        while IFS=$'\t' read -r _ _ status _ _; do
            [[ "$status" == "status" ]] && continue
            total=$((total + 1))
            case "$status" in
                PASS) pass=$((pass + 1));;
                FAIL) fail=$((fail + 1));;
                SKIP) skip=$((skip + 1));;
            esac
        done <"$TSV"
        echo "## Summary"
        echo
        echo "- Total runs: $total"
        echo "- PASS: $pass"
        echo "- FAIL: $fail"
        echo "- SKIP: $skip"
        echo
        echo "## All runs"
        echo
        echo "| Box | Scenario | Status | Time | Root cause |"
        echo "|-----|----------|--------|------|------------|"
        tail -n +2 "$TSV" | while IFS=$'\t' read -r box scen status dur cause; do
            printf "| %s | %s | %s | %ss | %s |\n" "$box" "$scen" "$status" "$dur" "${cause:--}"
        done
        echo
        echo "## Failures by root cause"
        echo
        tail -n +2 "$TSV" | awk -F'\t' '$3=="FAIL"{print $5}' | sort | uniq -c | sort -rn | \
            while read -r n cause; do echo "- $cause: $n"; done
        echo
        echo "## Per-failure detail (last 25 lines of each .fail.log)"
        echo
        tail -n +2 "$TSV" | awk -F'\t' '$3=="FAIL"{printf "%s %s\n",$1,$2}' | while read -r box scen; do
            local lf="$RESULTS/${box}-${scen}.fail.log"
            echo "### $box / $scen"
            echo
            echo '```'
            tail -25 "$lf" 2>/dev/null || echo "(log missing)"
            echo '```'
            echo
        done
    } >"$md"
    echo "Report written: $md"
}

report
exit "$exit_code"
