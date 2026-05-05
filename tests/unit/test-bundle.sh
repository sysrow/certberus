#!/bin/bash
# tests/unit/test-bundle.sh
# Builds bundle and verifies:
#   1. build/bundle.sh produces a single-file bash script
#   2. bundle has valid bash syntax
#   3. bundle --version matches build/VERSION
#   4. bundle contains all modules inline (no `source $CB_LIB_DIR/...`)
#   5. works from any cwd
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/env.sh"

cd "$CB_REPO_ROOT"

t_info "build/bundle.sh"
out=$(bash build/bundle.sh 2>&1); rc=$?
assert_exit_code "0" "$rc" "bundle.sh exit 0"
[[ $rc -ne 0 ]] && { echo "$out"; t_summary; }

bundle="$CB_REPO_ROOT/dist/certberus"
[[ -f "$bundle" ]] && t_pass "bundle produced: dist/certberus" || { t_fail "bundle not found"; t_summary; }

# bash -n
err=$(mktemp)
if bash -n "$bundle" 2>"$err"; then
    t_pass "bundle has valid bash syntax"
else
    t_fail "bundle syntax" "$(cat "$err")"
fi
rm -f "$err"

sz=$(stat -c %s "$bundle" 2>/dev/null || stat -f %z "$bundle")
if (( sz > 50000 && sz < 500000 )); then
    t_pass "bundle size reasonable ($sz B)"
else
    t_fail "bundle size: $sz B"
fi

# --version match s build/VERSION (kanonickym zdrojem)
canon_ver="$(tr -d '[:space:]' < build/VERSION)"
bundle_ver=$("$bundle" --version 2>&1 | awk '{print $2}')
src_ver=$(bin/certberus --version 2>&1 | awk '{print $2}')

# Bundle MUST have current version (build/VERSION). Src bin may diverge
# if build sync_version was not run - that is a separate bug.
assert_eq "$canon_ver" "$bundle_ver" "bundle --version == build/VERSION ($canon_ver)"
if [[ "$src_ver" != "$canon_ver" ]]; then
    t_skip "bin/certberus CB_VERSION=$src_ver does not match build/VERSION=$canon_ver - run 'bash build/build.sh sync-version'"
fi

# help works
help_out=$("$bundle" help 2>&1)
assert_exit_code "0" "$?" "bundle help exit 0"
assert_contains "$help_out" "auto"      "help: auto"
assert_contains "$help_out" "cert-info" "help: cert-info"

# Inline modules
contents=$(cat "$bundle")
for mod in cb_run_hooks cb_mod_md_adapter_body cb_firewall_acme_auto_open_enabled \
           cb_load_config cb_persist_config_skeleton cb_ensure_runtime_dirs \
           cb_validate_domain cmd_auto cmd_cert_info cmd_test_domain; do
    assert_contains "$contents" "$mod" "contains '$mod'"
done

# Bundle must contain embedded payloads for EVERY lib (integrity check).
for lib in common os dns firewall hooks discover preflight scan; do
    pat="__cb_payload_LIB_${lib^^}_SH"
    if grep -q "$pat" "$bundle"; then
        t_pass "bundle contains payload $lib.sh"
    else
        t_fail "bundle missing payload $lib.sh"
    fi
done

# Cwd-independent run
out=$(cd / && "$bundle" --version 2>&1); rc=$?
assert_exit_code "0" "$rc" "bundle works from cwd=/"

t_summary
