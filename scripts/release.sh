#!/usr/bin/env bash
# Publishes the version in VERSION: tags it, uploads the zip to a GitHub
# release, and updates the cask in the Homebrew tap.
# Needs a clean, pushed main branch, `gh` logged in as the repo owner, and
# the signing identity from scripts/dev-signing.sh: macOS ties the
# Accessibility grant to the signing certificate, so every release must be
# signed with the same one or users have to grant it again after updating.
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
REPO="amantibrewal310/Accio"
TAG="v$VERSION"
ZIP="$PROJECT_ROOT/dist/Accio-$VERSION.zip"

cd "$PROJECT_ROOT"
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Commit your changes first."
    exit 1
fi
if [ ! -f "$HOME/Library/Keychains/accio-dev.keychain-db" ] || [ -n "$ACCIO_SIGN_IDENTITY" ]; then
    echo "❌ Releases are signed with the identity from scripts/dev-signing.sh (and no ACCIO_SIGN_IDENTITY)."
    exit 1
fi

"$PROJECT_ROOT/scripts/package.sh"
codesign -dvv "$PROJECT_ROOT/build/Accio.app" 2>&1 | grep -q "Authority=Accio Local Development" \
    || { echo "❌ Accio.app isn't signed with Accio Local Development."; exit 1; }
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

echo "🏷  Tagging $TAG..."
git tag -a "$TAG" -m "Accio $VERSION"
git push origin "$TAG"

echo "🚀 Creating GitHub release..."
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Accio $VERSION" \
    --notes "Install with Homebrew (Apple Silicon, macOS 26+):

\`\`\`
brew install --cask amantibrewal310/tap/accio
\`\`\`

Accio isn't notarized. Homebrew lifts the download quarantine so it opens normally; if you download the zip yourself, macOS blocks the first launch: open it once, then click **Open Anyway** in System Settings → Privacy & Security."

echo "🍺 Updating the Homebrew tap..."
TAP_DIR="$(mktemp -d)"
# Same remote style and git identity as this repo (both can be per-folder settings)
TAP_URL="$(git remote get-url origin | sed 's#/Accio\(\.git\)\{0,1\}$#/homebrew-tap.git#')"
git clone -q "$TAP_URL" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" \
    "$PROJECT_ROOT/packaging/accio.rb" > "$TAP_DIR/Casks/accio.rb"
git -C "$TAP_DIR" add Casks/accio.rb
git -C "$TAP_DIR" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
    commit -m "accio $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "$TAP_DIR"

echo "✨ Released $TAG. Install with: brew install --cask amantibrewal310/tap/accio"
