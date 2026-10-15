#!/bin/sh
# 编译后台服务和菜单栏 App，打包成可直接运行的 BatteryCycle.app 和 BatteryCycle.zip
set -e
cd "$(dirname "$0")"
ROOT=..

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/BatteryCycle.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BatteryCycle" "$APP/Contents/MacOS/BatteryCycle"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# 后台服务和安装脚本放进 App，由 App 里的“安装后台服务”按钮调用
clang -O2 -Wall -Wextra -arch arm64 -o "$APP/Contents/Resources/batteryd" \
    "$ROOT/main.c" "$ROOT/smc.c" -framework IOKit -framework CoreFoundation
cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/com.local.batteryd.plist" "$APP/Contents/Resources/"

VERSION="${VERSION:-1.0.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BatteryCycle</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.batterycycle</string>
    <key>CFBundleName</key>
    <string>BatteryCycle</string>
    <key>CFBundleDisplayName</key>
    <string>电池循环</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- 只在菜单栏显示，不出现在 Dock -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# 没有开发者证书，用 ad-hoc 签名（先签内部的可执行文件，再签整个 App）
codesign --force --sign - "$APP/Contents/Resources/batteryd"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" build/BatteryCycle.zip
echo "已生成 app/$APP 和 app/build/BatteryCycle.zip"
