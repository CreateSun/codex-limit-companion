#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${APP_DIR:-$PROJECT_DIR/.build/package/CodexLimitCompanion.app}"
CONFIGURATION="${CONFIGURATION:-release}"

swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CodexLimitCompanion" "$APP_DIR/Contents/MacOS/CodexLimitCompanion"
cp -R "$BIN_DIR/CodexLimitCompanion_CodexLimitCompanion.bundle" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PROJECT_DIR/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$PROJECT_DIR/Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"
