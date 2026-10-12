#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/CodexLimitCompanion.app"
CONFIGURATION="${CONFIGURATION:-release}"

swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/CodexLimitCompanion" "$APP_DIR/Contents/MacOS/CodexLimitCompanion"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"
