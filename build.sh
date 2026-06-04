#!/bin/bash
# 把 SwiftPM 产物打包成 macOS .app bundle
# 用法:
#   ./build.sh           # 打包到当前目录的 PromptKeyboard.app
#   ./build.sh install   # 打包并复制到 /Applications

set -euo pipefail

APP_NAME="PromptKeyboard"
DISPLAY_NAME="提示词键盘"
BUNDLE_ID="com.nate.promptkeyboard"
VERSION="1.0"
BUILD="1"
MIN_OS="14.0"

cd "$(dirname "$0")"

echo "→ swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "✗ 找不到可执行文件: $BIN"
  exit 1
fi

APP_DIR="$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "→ 复制可执行文件"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "→ 生成 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>需要发送键盘事件到当前活动窗口,把提示词输入到 Claude Code 终端。</string>
</dict>
</plist>
EOF

# 生成图标(如果 make_icon.sh 存在)
if [ -x "./make_icon.sh" ]; then
  echo "→ 生成图标"
  ./make_icon.sh "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "→ ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR" 2>&1 | grep -v '^$' || true

if [ "${1:-}" = "install" ]; then
  echo "→ 复制到 /Applications"
  rm -rf "/Applications/$APP_DIR"
  # 用 ditto 而不是 cp -R:macOS TCC (App Management) 会静默拦截
  # cp -R 到 /Applications(exit 0 但目录是空壳),ditto 走 copyfile API 可以过
  ditto "$APP_DIR" "/Applications/$APP_DIR"
  # 事后校验:可执行文件存在且非空才算装成功
  if [ ! -x "/Applications/$APP_DIR/Contents/MacOS/$APP_NAME" ]; then
    echo "✗ 安装失败 — /Applications/$APP_DIR 里没有可执行文件"
    echo "  可能是 Terminal 没有「App Management」权限。"
    echo "  系统设置 → 隐私与安全性 → App 管理 → 把当前终端加进去,重试。"
    exit 1
  fi
  echo "✓ 已安装到 /Applications/$APP_DIR"
  echo ""
  echo "下一步:"
  echo "  1. 打开访达 → 应用程序 → 双击「${APP_NAME}」启动"
  echo "  2. 首次启动可能被 Gatekeeper 拦截,在「系统设置 → 隐私与安全性」最下方点「仍要打开」"
  echo "  3. 点悬浮窗按钮时会请求「辅助功能」权限,授权即可"
else
  echo "✓ 已生成: ./$APP_DIR"
  echo "  双击启动,或运行: ./build.sh install 安装到 /Applications"
fi
