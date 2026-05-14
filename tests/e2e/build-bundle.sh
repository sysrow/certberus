#!/bin/bash
# tests/e2e/build-bundle.sh - build a .deb and a single-file bundle from the
# current working tree, ready to scp to a chaos test box.
#
# Outputs:
#   dist/certberus_<VERSION>_all.deb
#   dist/certberus-<VERSION>.bundle
#
# Without docker we fall back to bundle-only. Most scenarios install via .deb
# (proper systemd integration); the bundle is the fallback for boxes where we
# do not want to leave package state behind.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

bash build/build.sh sync-version
bash build/build.sh bundle

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    bash build/build.sh deb
else
    echo "build-bundle.sh: docker unavailable, skipping .deb (bundle only)" >&2
fi

echo
echo "Artifacts in $REPO/dist/:"
ls -lh "$REPO/dist/"
