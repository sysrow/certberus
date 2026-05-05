#!/bin/bash
# tests/unit/test-syntax.sh
# Bash syntax (bash -n) check for all shell files in the repo.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"

cd "$CB_REPO_ROOT"

t_info "bash -n on all shell scripts"

declare -a files=(bin/certberus install.sh)
while IFS= read -r f; do files+=("$f"); done < <(
    find lib webservers build hooks tests -type f \( -name '*.sh' -o -name 'certberus' \) 2>/dev/null
)

err=$(mktemp 2>/dev/null || echo /tmp/.cb_syn.$$)
for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>"$err"; then
        t_pass "$f"
    else
        t_fail "$f" "$(cat "$err")"
    fi
done
rm -f "$err"

t_summary
