#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Install target defaults to ~/Applications. The bundle path is baked into the
# login item, so it must not live beside the source tree or inside any
# throwaway working directory.
OUTPUT_DIR="${CODEX_HUD_OUTPUT_DIR:-$HOME/Applications}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_DIR="$OUTPUT_DIR/Codex Usage HUD.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-hud.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP_DIR="$STAGING_DIR/Codex Usage HUD.app"
STAGED_CONTENTS_DIR="$STAGED_APP_DIR/Contents"
STAGED_MACOS_DIR="$STAGED_CONTENTS_DIR/MacOS"

swift build -c release --package-path "$ROOT_DIR"
swift run -c debug --package-path "$ROOT_DIR" CodexUsageHUDCoreTests

BUILD_BIN="$ROOT_DIR/.build/release/CodexUsageHUD"
if [[ ! -x "$BUILD_BIN" ]]; then
    echo "release executable not found: $BUILD_BIN" >&2
    exit 1
fi

mkdir -p "$STAGED_MACOS_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$BUILD_BIN" "$STAGED_MACOS_DIR/CodexUsageHUD"
ditto --norsrc --noextattr --noqtn --noacl "$ROOT_DIR/Resources/Info.plist" "$STAGED_CONTENTS_DIR/Info.plist"

# Build and sign in a clean temporary directory so Finder/File Provider
# metadata from the shared output folder cannot enter the signed bundle.
xattr -cr "$STAGED_APP_DIR"
codesign --force --deep --sign - "$STAGED_APP_DIR"
codesign --verify --deep --strict "$STAGED_APP_DIR"

# Replace only the exact requested output artifact with the verified bundle.
rm -rf "$APP_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$STAGED_APP_DIR" "$APP_DIR"
# A synced Documents folder may add metadata during the final copy. Keep the
# output clean and verify it once more before returning.
xattr -cr "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Packaged: $APP_DIR"
