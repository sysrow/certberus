#!/bin/bash
# tests/unit/test-hooks-runtime.sh
#
# v0.1.5 area: cb_run_hooks + cb_ensure_runtime_dirs.
# Real-world bug from example.com: hooks directories existed, but ensure_runtime_dirs
# did not create them immediately, so the first mod_md event hooks just silently logged.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

SANDBOX="$(t_mktempdir hooks-runtime)" || exit 1
trap 't_cleanup' EXIT

t_stub_log_helpers
t_isolate_cb_dirs "$SANDBOX"
mkdir -p "$CB_HOOKS_DIR/post-issue.d"

# shellcheck disable=SC1091
source "$CB_REPO_ROOT/lib/hooks.sh"

# Test 1: hook runs
cat > "$CB_HOOKS_DIR/post-issue.d/10-marker.sh" <<EOF
#!/bin/bash
echo "fired:\$CA_EVENT:\$CA_WEBSERVER:\$CA_PRIMARY_DOMAIN" > "$SANDBOX/m1"
EOF
chmod +x "$CB_HOOKS_DIR/post-issue.d/10-marker.sh"

CA_WEBSERVER="apache" CA_PRIMARY_DOMAIN="t.example.com" CA_DOMAIN_LIST="t.example.com" \
    cb_run_hooks post-issue
assert_file_exists "$SANDBOX/m1" "hook executed"
assert_eq "fired:post-issue:apache:t.example.com" "$(cat "$SANDBOX/m1" 2>/dev/null)" \
    "CA_* env reaches the hook"

# Test 2: .example/.bak/.disabled are ignored
cat > "$CB_HOOKS_DIR/post-issue.d/20-bad.sh.example" <<EOF
#!/bin/bash
echo fired > "$SANDBOX/example_fired"
EOF
chmod +x "$CB_HOOKS_DIR/post-issue.d/20-bad.sh.example"
cat > "$CB_HOOKS_DIR/post-issue.d/30-old.bak" <<EOF
#!/bin/bash
echo fired > "$SANDBOX/bak_fired"
EOF
chmod +x "$CB_HOOKS_DIR/post-issue.d/30-old.bak"

cb_run_hooks post-issue
[[ ! -f "$SANDBOX/example_fired" ]] && t_pass ".example ignored" || t_fail ".example executed"
[[ ! -f "$SANDBOX/bak_fired" ]]     && t_pass ".bak ignored"     || t_fail ".bak executed"

# Test 3: non-executable is not run
echo "echo NOEXEC" > "$CB_HOOKS_DIR/post-issue.d/40-noexec.sh"
chmod -x "$CB_HOOKS_DIR/post-issue.d/40-noexec.sh"
out=$(cb_run_hooks post-issue 2>&1 || true)
assert_not_contains "$out" "NOEXEC" "non-executable skipped"

# Test 4: hanging hook + CB_HOOK_TIMEOUT
mkdir -p "$CB_HOOKS_DIR/expiring.d"
cat > "$CB_HOOKS_DIR/expiring.d/10-hang.sh" <<EOF
#!/bin/bash
sleep 30
echo done > "$SANDBOX/hang"
EOF
chmod +x "$CB_HOOKS_DIR/expiring.d/10-hang.sh"
start=$SECONDS
CB_HOOK_TIMEOUT=2 cb_run_hooks expiring 2>/dev/null || true
elapsed=$(( SECONDS - start ))
if (( elapsed < 10 )); then
    t_pass "CB_HOOK_TIMEOUT=2 killed hanging hook (${elapsed}s)"
else
    t_fail "CB_HOOK_TIMEOUT did not work" "elapsed=${elapsed}s"
fi
[[ ! -f "$SANDBOX/hang" ]] && t_pass "hanging hook did not finish" || t_fail "hook passed through timeout"

# Test 5: non-existent event is a silent no-op
out=$(cb_run_hooks does-not-exist 2>&1 || true); rc=$?
assert_eq "" "$out" "non-existent event = silent"
assert_exit_code "0" "$rc" "non-existent event = exit 0"

# Test 6: pre-* fail propagates rc!=0
mkdir -p "$CB_HOOKS_DIR/pre-issue.d"
cat > "$CB_HOOKS_DIR/pre-issue.d/10-fail.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
chmod +x "$CB_HOOKS_DIR/pre-issue.d/10-fail.sh"
cb_run_hooks pre-issue 2>/dev/null
rc=$?
[[ $rc -ne 0 ]] && t_pass "pre-issue fail rc!=0 (rc=$rc)" || t_fail "pre-issue fail rc=$rc"

# Test 7: cb_ensure_runtime_dirs creates all event.d/ directories.
# common.sh checks id -u == 0; we run it via bash -c with id() override in a subshell.
CB_PREFIX="$SANDBOX/etc2"
CB_HOOKS_DIR="$SANDBOX/etc2/hooks"
CB_LOG_DIR="$SANDBOX/etc2/log"
CB_STATE_DIR="$SANDBOX/etc2/lib"
CB_BACKUP_DIR="$SANDBOX/etc2/backup"
export CB_PREFIX CB_HOOKS_DIR CB_LOG_DIR CB_STATE_DIR CB_BACKUP_DIR

bash -c '
    id() { echo 0; }
    export -f id 2>/dev/null || true
    set +u
    source "'"$CB_REPO_ROOT"'/lib/common.sh" 2>/dev/null
    cb_ensure_runtime_dirs
' 2>/dev/null || true

for ev in pre-issue post-issue post-reload renewing renewed installed errored \
          ocsp-renewed ocsp-errored on-failure deploy; do
    assert_dir_exists "$CB_HOOKS_DIR/$ev.d" "ensure_runtime_dirs: $ev.d"
done
assert_file_exists "$CB_HOOKS_DIR/README" "README in hooks/"

t_summary
