#!/bin/bash
# tests/unit/test-apache-md-ca-reset.sh
#
# Regression test for stage_reset_store_on_ca_change. Two bugs this guards:
#   1) Switching CA was a no-op: a mod_md store issued by a different CA was
#      left in place, so mod_md kept serving the old certificate and never
#      re-issued from the newly configured CA.
#   2) The first attempt at (1) moved the stale store to
#      domains/<name>.certberus-bak-* - INSIDE the store. mod_md scans every
#      subdirectory of domains/ and aborts with AH10073 if one is not a
#      well-formed MD, taking Apache down. The backup must live outside the
#      store, and a misplaced one from an older run must be self-healed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/env.sh"

SANDBOX=$(t_mktempdir)
trap 't_cleanup' EXIT
t_isolate_cb_dirs "$SANDBOX"

# The mod_md store lives in the sandbox, not the real /etc/apache2/md.
export CB_MOD_MD_APACHE_STORE_ROOT="$SANDBOX/md"
MD="$CB_MOD_MD_APACHE_STORE_ROOT"
mkdir -p "$MD/domains" "$MD/staging" "$MD/tmp"

# Source-time defaults for apache-md.sh
export CB_OS_ID=debian
export CB_OS_VERSION=13
export CB_PKG_MGR=apt
export CB_DRY_RUN=0
export CB_ASSUME_YES=1
export CB_AUTO_ROLLBACK=0
: > "$CB_CONFIG_FILE"
: > "$CB_ADVANCED_FILE"

# Source apache-md.sh WITHOUT triggering its trailing `main "$@"` invocation -
# we only want the function definitions.
# shellcheck disable=SC1091
source <(sed '$d' "$CB_REPO_ROOT/webservers/apache-md.sh")

LE_URL="https://acme-v02.api.letsencrypt.org/directory"
OTHER_URL="https://acme-v02.example-ca.org/acme/abc123/directory"

# mk_md <domain> <ca_url> - create a minimal but well-formed MD store entry
mk_md() {
    local d="$1" url="$2"
    mkdir -p "$MD/domains/$d"
    cat > "$MD/domains/$d/md.json" <<JSON
{ "name": "$d", "domains": ["$d"], "ca": { "url": "$url" }, "state": 2 }
JSON
    echo "cert" > "$MD/domains/$d/pubcert.pem"
}

# ----------------------------------------------------------------------------
t_info "Case 1: store CA differs from configured CA -> store moved OUT of store"
mk_md camismatch.example.com "$OTHER_URL"
echo "camismatch.example.com" > "$CB_VALID_DOMAINS_FILE"
_CB_RESOLVED_CA_URL="$LE_URL"
stage_reset_store_on_ca_change >/dev/null 2>&1

assert_dir_exists "$CB_BACKUP_DIR/md-store-stale-ca" "backup root created outside the mod_md store"
if [[ -d "$MD/domains/camismatch.example.com" ]]; then
    t_fail "stale store removed from domains/" "still present"
else
    t_pass "stale store removed from domains/"
fi
shopt -s nullglob
leftover=("$MD"/domains/*.certberus-bak-*)
shopt -u nullglob
assert_eq 0 "${#leftover[@]}" "no backup dir left inside domains/"
shopt -s nullglob
bk=("$CB_BACKUP_DIR"/md-store-stale-ca/camismatch.example.com-*)
shopt -u nullglob
if [[ ${#bk[@]} -gt 0 && -f "${bk[0]}/md.json" ]]; then
    t_pass "stale store preserved in the external backup location"
else
    t_fail "external backup" "md.json not found under $CB_BACKUP_DIR/md-store-stale-ca"
fi

# ----------------------------------------------------------------------------
t_info "Case 2: store CA matches configured CA -> store left untouched"
mk_md camatch.example.com "$LE_URL"
echo "camatch.example.com" > "$CB_VALID_DOMAINS_FILE"
_CB_RESOLVED_CA_URL="$LE_URL"
stage_reset_store_on_ca_change >/dev/null 2>&1
assert_dir_exists "$MD/domains/camatch.example.com" "matching-CA store kept in place"

# ----------------------------------------------------------------------------
t_info "Case 3: self-heal - a misplaced backup inside domains/ is relocated out"
legacy="$MD/domains/legacy.example.com.certberus-bak-20260101_000000"
mkdir -p "$legacy"
echo '{ "name": "legacy.example.com" }' > "$legacy/md.json"
echo "camatch.example.com" > "$CB_VALID_DOMAINS_FILE"
_CB_RESOLVED_CA_URL="$LE_URL"
stage_reset_store_on_ca_change >/dev/null 2>&1
shopt -s nullglob
leftover=("$MD"/domains/*.certberus-bak-*)
shopt -u nullglob
assert_eq 0 "${#leftover[@]}" "misplaced backup relocated out of domains/"
assert_dir_exists \
    "$CB_BACKUP_DIR/md-store-stale-ca/legacy.example.com.certberus-bak-20260101_000000" \
    "misplaced backup now lives outside the store"

t_summary
