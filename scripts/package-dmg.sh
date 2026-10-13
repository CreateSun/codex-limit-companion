#!/bin/zsh
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: zsh scripts/package-dmg.sh /path/to/CodexLimitCompanion.app /path/to/output.dmg'
  exit 1
fi
APP_PATH="${1:A}"
DMG_PATH="${2:A}"
[[ -d "$APP_PATH/Contents/MacOS" ]] || { print -u2 'App bundle not found'; exit 1; }
[[ ! -e "$DMG_PATH" ]] || { print -u2 'Output already exists'; exit 1; }
codesign --verify --deep --strict "$APP_PATH"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-companion-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/CodexLimitCompanion.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/安装说明.txt" <<'GUIDE'
Codex Limit Companion

将 CodexLimitCompanion.app 拖入 Applications（应用程序），然后从应用程序启动。
升级前请退出旧版。应用驻留于 macOS 顶部菜单栏，不显示 Dock 图标。

需要 macOS 14+、Apple Silicon，以及已安装并登录的 Codex CLI。
安装包为临时签名，未经 Apple 公证。如被阻止，请在系统设置 → 隐私与安全性中检查，或从源码构建。

项目与使用指南：https://github.com/CreateSun/codex-limit-companion
GUIDE
mkdir -p "${DMG_PATH:h}"
hdiutil create -volname 'Codex Limit Companion' -srcfolder "$STAGING_DIR" -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
