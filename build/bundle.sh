#!/bin/bash
# build/bundle.sh - produces a single-file, self-contained certberus executable.
#
# Output:  dist/certberus   (one bash file, ~120 KB, no runtime deps besides bash + standard utils)
#
# Use:
#   ./build/bundle.sh
#   sudo cp dist/certberus /usr/local/sbin/certberus
#   # or just: ./dist/certberus interactive

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC_BIN="$ROOT/bin/certberus"
SRC_LIB="$ROOT/lib"
SRC_WS="$ROOT/webservers"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/certberus"

mkdir -p "$OUT_DIR"

VERSION="$(awk -F'"' '/^CB_VERSION=/{print $2; exit}' "$SRC_BIN")"
[[ -n "$VERSION" ]] || VERSION="0.0.0"

echo "Bundling certberus v$VERSION -> $OUT"

# Helper: emit a here-doc with a given quoted delimiter; escape \ and the delimiter.
# We use 'CERTBERUS_EOF_<UPPER>' as the delimiter so file contents never collide.
emit_payload() {
    local label="$1" path="$2"
    local delim="CERTBERUS_PAYLOAD_${label}_EOF"
    printf '__cb_payload_%s() {\n' "$label"
    printf "cat <<'%s'\n" "$delim"
    cat "$path"
    printf '\n%s\n' "$delim"
    printf '}\n\n'
}

{
    # ---- Bundle header ----------------------------------------------------
    cat <<HEADER
#!/bin/bash
# certberus v$VERSION - single-file bundle
# Built: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
# Source: https://github.com/Tristram1337/certberus
#
# This file embeds bin/certberus + lib/*.sh + webservers/*.sh.
# At startup it extracts the embedded scripts to a private temp directory,
# sources them, and dispatches to the original entrypoint. The temp
# directory is cleaned up on exit.
#
# Usage is identical to the unbundled version:
#   ./certberus interactive
#   ./certberus auto
#   ./certberus doctor

set -uo pipefail
CB_VERSION="$VERSION"

HEADER

    # ---- Embedded payloads ------------------------------------------------
    echo "# ============================================================"
    echo "# Embedded payloads (each function emits one source file)"
    echo "# ============================================================"
    echo

    # Library payloads (order matters: load common.sh first)
    LIB_FILES=(common.sh os.sh dns.sh firewall.sh hooks.sh discover.sh preflight.sh)
    for f in "${LIB_FILES[@]}"; do
        [[ -f "$SRC_LIB/$f" ]] || { echo "Missing $SRC_LIB/$f" >&2; exit 2; }
        label="LIB_$(echo "$f" | tr 'a-z.-' 'A-Z__')"
        emit_payload "$label" "$SRC_LIB/$f"
    done

    # Webserver payloads
    WS_FILES=(apache-md.sh apache-md-eab.sh nginx-certbot.sh tomcat-certbot.sh)
    for f in "${WS_FILES[@]}"; do
        [[ -f "$SRC_WS/$f" ]] || { echo "Missing $SRC_WS/$f" >&2; exit 2; }
        label="WS_$(echo "$f" | tr 'a-z.-' 'A-Z__')"
        emit_payload "$label" "$SRC_WS/$f"
    done

    # ---- Bootstrap: extract payloads to a temp dir ------------------------
    cat <<'BOOTSTRAP'
# ============================================================
# Bootstrap: unpack embedded payloads to a private temp dir
# ============================================================

CB_BUNDLE_TMP="$(mktemp -d -t certberus-bundle.XXXXXX)" || {
    echo "[ERR] Cannot create temp dir for bundle." >&2
    exit 2
}
trap 'rm -rf "$CB_BUNDLE_TMP"' EXIT

mkdir -p "$CB_BUNDLE_TMP/lib" "$CB_BUNDLE_TMP/webservers"

# Lib files
__cb_payload_LIB_COMMON_SH    > "$CB_BUNDLE_TMP/lib/common.sh"
__cb_payload_LIB_OS_SH        > "$CB_BUNDLE_TMP/lib/os.sh"
__cb_payload_LIB_DNS_SH       > "$CB_BUNDLE_TMP/lib/dns.sh"
__cb_payload_LIB_FIREWALL_SH  > "$CB_BUNDLE_TMP/lib/firewall.sh"
__cb_payload_LIB_HOOKS_SH     > "$CB_BUNDLE_TMP/lib/hooks.sh"
__cb_payload_LIB_DISCOVER_SH  > "$CB_BUNDLE_TMP/lib/discover.sh"
__cb_payload_LIB_PREFLIGHT_SH > "$CB_BUNDLE_TMP/lib/preflight.sh"

# Webserver scripts (executable: spawned as subprocesses by the orchestrator)
__cb_payload_WS_APACHE_MD_SH      > "$CB_BUNDLE_TMP/webservers/apache-md.sh"
__cb_payload_WS_APACHE_MD_EAB_SH  > "$CB_BUNDLE_TMP/webservers/apache-md-eab.sh"
__cb_payload_WS_NGINX_CERTBOT_SH  > "$CB_BUNDLE_TMP/webservers/nginx-certbot.sh"
__cb_payload_WS_TOMCAT_CERTBOT_SH > "$CB_BUNDLE_TMP/webservers/tomcat-certbot.sh"
chmod +x "$CB_BUNDLE_TMP/webservers/"*.sh

# Tell the orchestrator where to find everything (overrides path autodetection).
export CB_LIB_DIR="$CB_BUNDLE_TMP/lib"
export CB_WEBSERVERS_DIR="$CB_BUNDLE_TMP/webservers"

# ============================================================
# Source the libraries (we replicate bin/certberus startup, minus
# the on-disk path search - we already know where the files are).
# ============================================================
# shellcheck disable=SC1091
source "$CB_LIB_DIR/common.sh"
source "$CB_LIB_DIR/os.sh"
source "$CB_LIB_DIR/dns.sh"
source "$CB_LIB_DIR/firewall.sh"
source "$CB_LIB_DIR/hooks.sh"
source "$CB_LIB_DIR/discover.sh"
cb_load_config
cb_ensure_runtime_dirs

BOOTSTRAP

    # ---- Inline the orchestrator body (skip its own loader) ---------------
    # We strip:
    #   - shebang (already at top)
    #   - the path-autodetection block that ends at `cb_load_config`
    # Then we append the rest verbatim.
    awk '
        # Skip everything up to and including the first "cb_load_config" line.
        !done && /^cb_load_config[[:space:]]*$/ { done=1; next }
        done { print }
    ' "$SRC_BIN"

} > "$OUT"

chmod +x "$OUT"

# Sanity: bash syntax check
if ! bash -n "$OUT"; then
    echo "FAIL: generated bundle has syntax errors" >&2
    exit 3
fi

SIZE=$(wc -c < "$OUT" | tr -d ' ')
SHA=$(sha256sum "$OUT" | awk '{print $1}')
echo "OK   $OUT  ($SIZE bytes)"
echo "SHA  $SHA"
echo
echo "Run:  ./dist/certberus help"
