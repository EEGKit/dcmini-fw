#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CRATE_DIR="$ROOT_DIR/crates/dc-mini-host"
DIST_DIR="$ROOT_DIR/dist"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
BIN_PATH="$TARGET_DIR/release/gui-rr"
APP_NAME="GuiRR.app"
APP_DIR="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ZIP_PATH="$DIST_DIR/gui-rr-macos-arm64.zip"
BUNDLE_ID="${BUNDLE_ID:-com.dcmini.gui-rr}"
VERSION="${VERSION:-0.1.1}"
MIN_MACOS="${MIN_MACOS:-13.0}"
ICON_SOURCE="${ICON_SOURCE:-$CRATE_DIR/assets/128x128.png}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--skip-build] [--version VERSION] [--bundle-id BUNDLE_ID] [--min-macos VERSION]

Builds the unsigned macOS release bundle for gui-rr, vendors any non-system
libiconv dependency into the app bundle, and creates a shareable zip at:
  $ZIP_PATH

Environment overrides:
  CARGO_TARGET_DIR   Cargo target directory
  BUNDLE_ID          App bundle identifier (default: $BUNDLE_ID)
  VERSION            App version string (default: $VERSION)
  MIN_MACOS          LSMinimumSystemVersion (default: $MIN_MACOS)
  ICON_SOURCE        PNG copied into Contents/Resources
USAGE
}

SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --min-macos)
      MIN_MACOS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd cargo
require_cmd otool
require_cmd ditto
require_cmd install_name_tool

mkdir -p "$DIST_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> Building gui-rr release binary"
  cargo build -p dc-mini-host --bin gui-rr --release --manifest-path "$ROOT_DIR/Cargo.toml"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Missing built binary: $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/gui-rr"
chmod +x "$MACOS_DIR/gui-rr"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/"
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GuiRR</string>
  <key>CFBundleDisplayName</key><string>GuiRR</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>gui-rr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

iconv_dep="$(otool -L "$MACOS_DIR/gui-rr" | awk '/libiconv\.2\.dylib/ {print $1; exit}')"
if [[ -n "$iconv_dep" ]]; then
  case "$iconv_dep" in
    /System/*|/usr/lib/*|@executable_path/*|@rpath/*)
      echo "==> libiconv dependency already portable: $iconv_dep"
      ;;
    *)
      echo "==> Vendoring libiconv from: $iconv_dep"
      if [[ ! -f "$iconv_dep" ]]; then
        echo "Resolved libiconv path does not exist: $iconv_dep" >&2
        exit 1
      fi
      cp "$iconv_dep" "$FRAMEWORKS_DIR/libiconv.2.dylib"
      chmod 0644 "$FRAMEWORKS_DIR/libiconv.2.dylib"
      install_name_tool -change \
        "$iconv_dep" \
        '@executable_path/../Frameworks/libiconv.2.dylib' \
        "$MACOS_DIR/gui-rr"
      ;;
  esac
fi

echo "==> Final linked libraries"
otool -L "$MACOS_DIR/gui-rr"

rm -f "$ZIP_PATH"
echo "==> Creating zip: $ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "Created: $ZIP_PATH"
echo "Unsigned app bundle: $APP_DIR"
echo "If Gatekeeper blocks it on another Mac, use right-click Open or remove quarantine with:"
echo "  xattr -dr com.apple.quarantine $APP_NAME"
