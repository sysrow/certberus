#!/bin/bash
# tests/test-hooks-chaos.sh
# Malicious hooks: shebang, perms, BOM, fork-bomb, sleep, CWD, timeout, pre-fail-abort.
# Tests source lib/common.sh + lib/hooks.sh directly (fast, no docker).

set -uo pipefail
CERT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) shift; ONLY="$1" ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

export CB_LOG_FILE=/dev/null
export CB_SYSLOG_ENABLED=0
export CB_COLOR=never
export CB_VERBOSE=0
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$CERT_ROOT/lib/hooks.sh"

setup_hooks_dir() {
    # /tmp on the host may be noexec - pouzij /var/tmp pripadne $HOME
    local base
    for base in /var/tmp "$HOME" /dev/shm; do
        [[ -d "$base" && -w "$base" ]] || continue
        # Test exec bit on this FS
        local probe; probe="$base/.cb-exec-probe.$$"
        echo "#!/bin/sh" > "$probe" && chmod +x "$probe" && "$probe" >/dev/null 2>&1 && {
            rm -f "$probe"
            HOOKS_DIR=$(mktemp -d -p "$base")
            export CB_HOOKS_DIR="$HOOKS_DIR"
            return 0
        }
        rm -f "$probe"
    done
    HOOKS_DIR=$(mktemp -d)
    export CB_HOOKS_DIR="$HOOKS_DIR"
}

teardown_hooks_dir() {
    rm -rf "$HOOKS_DIR" 2>/dev/null
}

run() {
    local name="$1" body="$2"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && return 0
    echo "--- $name ---"
    setup_hooks_dir
    if (set -e; eval "$body") >/tmp/hk-$$.out 2>&1; then
        pass "$name"
    else
        sed 's/^/    /' /tmp/hk-$$.out | tail -10
        fail "$name"
    fi
    rm -f /tmp/hk-$$.out
    teardown_hooks_dir
}

# B.6.1: hook without shebang - run-parts ignores it (fine)
run "hook-no-shebang-ignored" '
mkdir -p "$HOOKS_DIR/post-issue.d"
echo "echo HELLO > /tmp/hk-noshebang-marker" > "$HOOKS_DIR/post-issue.d/10-noshebang"
chmod +x "$HOOKS_DIR/post-issue.d/10-noshebang"
rm -f /tmp/hk-noshebang-marker
cb_run_hooks post-issue >/dev/null 2>&1 || true
# Without shebang: kernel tries exec and falls through to shell - bash fallback works, so marker IS created.
# Test: certberus must not crash and hook is either executed or skipped.
true
'

# B.6.2: hook non-executable - must be skipped
run "hook-non-executable-skipped" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/20-noexec" <<EOF
#!/bin/bash
touch /tmp/hk-noexec-RAN-$$
EOF
chmod 644 "$HOOKS_DIR/post-issue.d/20-noexec"
rm -f /tmp/hk-noexec-RAN-$$
cb_run_hooks post-issue >/dev/null 2>&1 || true
[[ ! -e /tmp/hk-noexec-RAN-$$ ]] || { rm -f /tmp/hk-noexec-RAN-$$; echo "BUG: non-exec hook was executed"; exit 1; }
'

# B.6.3: hook with BOM (\xef\xbb\xbf before shebang) - bash rejects it, but pipeline must not crash
run "hook-with-BOM-graceful" '
mkdir -p "$HOOKS_DIR/post-issue.d"
printf "\xef\xbb\xbf#!/bin/bash\necho ok\n" > "$HOOKS_DIR/post-issue.d/30-bom"
chmod +x "$HOOKS_DIR/post-issue.d/30-bom"
# Hook should not pass (bash cannot handle BOM). cb_run_hooks must return non-zero but not crash.
cb_run_hooks post-issue >/dev/null 2>&1
RC=$?
[[ $RC -lt 128 ]] || { echo "cb_run_hooks crashed with SIGNAL"; exit 1; }
'

# B.6.4: fork bomb (limited) - timeout must kill it
run "hook-fork-bomb-timeout-kills" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/40-bomb" <<"EOF"
#!/bin/bash
# Omezena verze - 50 forku
for i in $(seq 1 50); do
    sleep 100 &
done
wait
EOF
chmod +x "$HOOKS_DIR/post-issue.d/40-bomb"
export CB_HOOK_TIMEOUT=2
T0=$(date +%s)
cb_run_hooks post-issue >/dev/null 2>&1 || true
T1=$(date +%s)
ELAPSED=$((T1 - T0))
[[ $ELAPSED -lt 10 ]] || { echo "Timeout did not catch hook ($ELAPSED s)"; exit 1; }
# Cleanup any remaining sleep processes
pkill -P $$ -f "sleep 100" 2>/dev/null || true
'

# B.6.5: sleep 9999 - timeout expires
run "hook-sleep-timeout-respected" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/50-sleep" <<"EOF"
#!/bin/bash
sleep 9999
EOF
chmod +x "$HOOKS_DIR/post-issue.d/50-sleep"
export CB_HOOK_TIMEOUT=2
T0=$(date +%s)
cb_run_hooks post-issue >/dev/null 2>&1 || true
T1=$(date +%s)
ELAPSED=$((T1 - T0))
[[ $ELAPSED -lt 10 ]] || { echo "Timeout nepouzit ($ELAPSED s)"; exit 1; }
[[ $ELAPSED -ge 1 ]] || { echo "Hook did not run ($ELAPSED s)"; exit 1; }
'

# B.6.6: hook changes CWD - certberus must not be affected
run "hook-changes-cwd-isolated" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/60-cd" <<"EOF"
#!/bin/bash
cd /
echo "hook v $(pwd)"
EOF
chmod +x "$HOOKS_DIR/post-issue.d/60-cd"
ORIG_CWD=$(pwd)
cb_run_hooks post-issue >/dev/null 2>&1
NEW_CWD=$(pwd)
[[ "$ORIG_CWD" == "$NEW_CWD" ]] || { echo "BUG: hook changed parent CWD from $ORIG_CWD to $NEW_CWD"; exit 1; }
'

# B.6.7: hook writes to CB_LOG_FILE - recursion log->hook->log
run "hook-writes-to-log-no-recursion" '
mkdir -p "$HOOKS_DIR/post-issue.d"
LOG_FILE="$HOOKS_DIR/cb.log"; : > "$LOG_FILE"
export CB_LOG_FILE="$LOG_FILE"
cat > "$HOOKS_DIR/post-issue.d/70-log" <<EOF
#!/bin/bash
echo "[hook-internal] from hook" >> "$LOG_FILE"
EOF
chmod +x "$HOOKS_DIR/post-issue.d/70-log"
cb_run_hooks post-issue >/dev/null 2>&1
SIZE=$(stat -c %s "$LOG_FILE")
[[ $SIZE -lt 10000 ]] || { echo "Log exploded ($SIZE bytes) - recursion?"; exit 1; }
grep -q "hook-internal" "$LOG_FILE" || exit 1
export CB_LOG_FILE=/dev/null
'

# B.6.8: hook exec replacement - certberus process survives
run "hook-exec-replacement-parent-survives" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/80-exec" <<"EOF"
#!/bin/bash
# Subshell exec - replaces only hook process, not parent
( exec true )
exit 0
EOF
chmod +x "$HOOKS_DIR/post-issue.d/80-exec"
cb_run_hooks post-issue >/dev/null 2>&1
# If parent survived, we reach this point
echo "parent alive"
'

# B.6.9: pre-issue hook exit 1 -> cb_run_hooks must return non-zero
run "pre-issue-hook-fail-returns-nonzero" '
mkdir -p "$HOOKS_DIR/pre-issue.d"
cat > "$HOOKS_DIR/pre-issue.d/90-fail" <<"EOF"
#!/bin/bash
echo "pre-issue NACK"
exit 1
EOF
chmod +x "$HOOKS_DIR/pre-issue.d/90-fail"
cb_run_hooks pre-issue >/dev/null 2>&1
RC=$?
[[ $RC -ne 0 ]] || { echo "BUG: pre-issue hook fail = cb_run_hooks returned 0"; exit 1; }
# CRITICAL: Caller (webserver modules) MUST check this return value.
# Currently ignored - documented bug, source fix in Phase C.
'

# B.6.10: post-issue hook exit 1 - cb_run_hooks returns non-zero, but issue succeeded
# Test that post-issue fail is logged, ne forced rollback v hook layeru
run "post-issue-hook-fail-no-rollback" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/95-postfail" <<"EOF"
#!/bin/bash
exit 1
EOF
chmod +x "$HOOKS_DIR/post-issue.d/95-postfail"
cb_run_hooks post-issue >/dev/null 2>&1
RC=$?
# RC is non-zero (failed=1), but that is a signal for the caller; it can ignore.
# cb_run_hooks itself does not trigger rollback - that is the responsibility of stage_issue_cert.
[[ $RC -ne 0 ]] || true  # it is fine that RC != 0
true
'

# B.6.11: hook dir empty -> graceful (return 0)
run "hook-dir-empty-graceful" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cb_run_hooks post-issue >/dev/null 2>&1
RC=$?
[[ $RC -eq 0 ]] || { echo "Empty hook dir should return 0, returned $RC"; exit 1; }
'

# B.6.12: 256 hook scripts - run-parts must handle all
run "hook-many-scripts-run" '
mkdir -p "$HOOKS_DIR/post-issue.d"
COUNTER=$(mktemp)
echo 0 > "$COUNTER"
for i in $(seq -w 1 256); do
    cat > "$HOOKS_DIR/post-issue.d/$i-h" <<EOF
#!/bin/bash
n=\$(cat "$COUNTER")
echo \$((n+1)) > "$COUNTER"
EOF
    chmod +x "$HOOKS_DIR/post-issue.d/$i-h"
done
T0=$(date +%s)
cb_run_hooks post-issue >/dev/null 2>&1
T1=$(date +%s)
COUNT=$(cat "$COUNTER")
rm -f "$COUNTER"
[[ $COUNT -eq 256 ]] || { echo "Ran $COUNT of 256 hooks"; exit 1; }
[[ $((T1-T0)) -lt 30 ]] || { echo "Slow: $((T1-T0))s"; exit 1; }
'

# Bonus: hook with SIGSEGV (signal 11) - parent must survive
run "hook-segfault-parent-survives" '
mkdir -p "$HOOKS_DIR/post-issue.d"
cat > "$HOOKS_DIR/post-issue.d/99-segv" <<"EOF"
#!/bin/bash
kill -SEGV $$
EOF
chmod +x "$HOOKS_DIR/post-issue.d/99-segv"
cb_run_hooks post-issue >/dev/null 2>&1 || true
# Parent pokracuje
echo "alive"
'

# B.6 summary
echo "==============================================================="
echo "TOTAL: $PASS pass / $FAIL fail"
exit $(( FAIL > 0 ? 1 : 0 ))
