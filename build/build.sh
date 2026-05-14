#!/bin/bash
# build/build.sh - master build entry point for certberus
# Usage:
#   bash build/build.sh all                 # all formats
#   bash build/build.sh tarball|deb|rpm|apk|bundle
#   bash build/build.sh clean
#   bash build/build.sh sync-version        # writes VERSION into bin/certberus
#   bash build/build.sh smoke-test          # installs artifacts in Docker and verifies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
[[ -n "$VERSION" ]] || { echo "ERR: build/VERSION is empty"; exit 1; }

# Colors (TTY only)
if [[ -t 1 ]]; then
    C_B=$'\e[1m'; C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_0=$'\e[0m'
else
    C_B=""; C_G=""; C_R=""; C_Y=""; C_0=""
fi
say()  { echo "${C_B}== $*${C_0}"; }
ok()   { echo "${C_G}[OK]${C_0} $*"; }
warn() { echo "${C_Y}[WARN]${C_0} $*"; }
die()  { echo "${C_R}[ERR]${C_0} $*" >&2; exit 1; }

export DIST_DIR REPO_ROOT VERSION

mkdir -p "$DIST_DIR"

sync_version() {
    local file="$REPO_ROOT/bin/certberus"
    if grep -q "^CB_VERSION=" "$file"; then
        sed -i -E "s/^CB_VERSION=\"[^\"]*\"/CB_VERSION=\"$VERSION\"/" "$file"
        ok "bin/certberus CB_VERSION=\"$VERSION\""
    fi
}

clean() {
    say "Cleaning $DIST_DIR"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    ok "clean"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker is not available"
    docker info >/dev/null 2>&1 || die "Docker daemon is not running"
}

build_tarball() {
    say "Building tarball certberus-$VERSION.tar.gz"
    sync_version
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    local stage="$tmp/certberus-$VERSION"
    mkdir -p "$stage"
    # Copy only required files
    cp -R "$REPO_ROOT/bin"         "$stage/"
    cp -R "$REPO_ROOT/lib"         "$stage/"
    cp -R "$REPO_ROOT/webservers"  "$stage/"
    cp -R "$REPO_ROOT/config"      "$stage/"
    cp -R "$REPO_ROOT/hooks"       "$stage/"
    cp    "$REPO_ROOT/install.sh"  "$stage/"
    cp    "$REPO_ROOT/README.md"   "$stage/" 2>/dev/null || true
    cp    "$SCRIPT_DIR/VERSION"    "$stage/"
    # Permissions
    chmod 755 "$stage/install.sh" "$stage/bin/certberus"
    find "$stage/webservers" -name '*.sh' -exec chmod 755 {} \;
    find "$stage/lib" -name '*.sh' -exec chmod 644 {} \;
    # Tar (deterministic)
    tar --owner=0 --group=0 --numeric-owner \
        --sort=name --mtime='2024-01-01 00:00:00 UTC' \
        -czf "$DIST_DIR/certberus-$VERSION.tar.gz" \
        -C "$tmp" "certberus-$VERSION"
    ok "$DIST_DIR/certberus-$VERSION.tar.gz ($(du -h "$DIST_DIR/certberus-$VERSION.tar.gz" | awk '{print $1}'))"
}

build_deb() {
    say "Building .deb (Docker: debian:12)"
    sync_version
    require_docker
    docker run --rm --network=host \
        -v "$REPO_ROOT:/src:ro" \
        -v "$DIST_DIR:/dist" \
        -e VERSION="$VERSION" \
        -w /src \
        debian:12 \
        bash /src/build/deb.sh
    ok "$DIST_DIR/certberus_${VERSION}_all.deb"
}

build_rpm() {
    say "Building .rpm (Docker: rockylinux:8 - noarch, installs on EL9+ too)"
    sync_version
    require_docker
    docker run --rm --network=host \
        -v "$REPO_ROOT:/src:ro" \
        -v "$DIST_DIR:/dist" \
        -e VERSION="$VERSION" \
        -w /src \
        rockylinux:8 \
        bash /src/build/rpm.sh
    ok "$DIST_DIR/certberus-${VERSION}-1.noarch.rpm"
}

build_apk() {
    say "Building .apk (Docker: alpine:3.20)"
    sync_version
    require_docker
    docker run --rm --network=host \
        -v "$REPO_ROOT:/src:ro" \
        -v "$DIST_DIR:/dist" \
        -e VERSION="$VERSION" \
        -w /src \
        alpine:3.20 \
        sh /src/build/apk.sh
    ok "$DIST_DIR/certberus-${VERSION}-r0.apk"
}

smoke_test() {
    say "Smoke test of all artifacts"
    require_docker
    bash "$SCRIPT_DIR/smoke-test.sh"
}

cmd="${1:-all}"
build_bundle() {
    say "Building single-file bundle certberus-$VERSION.bundle"
    bash "$SCRIPT_DIR/bundle.sh"
    # bundle.sh produces dist/certberus - rename for the release artifact
    if [[ -f "$DIST_DIR/certberus" ]]; then
        mv "$DIST_DIR/certberus" "$DIST_DIR/certberus-$VERSION.bundle"
        ok "$DIST_DIR/certberus-$VERSION.bundle"
    fi
}

case "$cmd" in
    all)
        clean
        build_tarball
        build_deb
        build_rpm
        build_apk
        build_bundle
        say "Done. Artifacts in $DIST_DIR:"
        ls -lh "$DIST_DIR"
        ;;
    tarball) build_tarball ;;
    deb)     build_deb ;;
    rpm)     build_rpm ;;
    apk)     build_apk ;;
    bundle)  build_bundle ;;
    clean)   clean ;;
    sync-version) sync_version ;;
    smoke-test)   smoke_test ;;
    -h|--help|help)
        sed -n '2,8p' "$0"
        ;;
    *) die "Unknown command: $cmd (use: all|tarball|deb|rpm|apk|bundle|clean|smoke-test)" ;;
esac
