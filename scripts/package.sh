#!/usr/bin/env bash
# Builds Accio.app and zips it into dist/ for a release.
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
DIST="$PROJECT_ROOT/dist"
ZIP="$DIST/Accio-$VERSION.zip"

"$PROJECT_ROOT/scripts/build.sh"

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact
ditto -c -k --keepParent "$PROJECT_ROOT/build/Accio.app" "$ZIP"

echo "📦 $ZIP"
echo "   sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
