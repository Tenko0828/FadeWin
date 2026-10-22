#!/bin/zsh
# 编译并打包成 build/FadeWin.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=.build/release/FadeWin
APP=build/FadeWin.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FadeWin"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 用 App 自己的绘图代码渲染图标
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 用固定的签名要求，重新编译后「屏幕录制」授权不会失效
codesign --force --sign - -r='designated => identifier "local.tenko.fadewin"' "$APP" >/dev/null
echo "✓ 已生成 $APP"

# ./build.sh install：装进「应用程序」并设为开机启动
if [[ "${1:-}" == "install" ]]; then
  pkill -x FadeWin 2>/dev/null || true
  sleep 0.3
  rm -rf /Applications/FadeWin.app
  ditto "$APP" /Applications/FadeWin.app
  rm -rf "$APP"
  /Applications/FadeWin.app/Contents/MacOS/FadeWin --enable-login-item
  open /Applications/FadeWin.app
  echo "✓ 已安装到 /Applications/FadeWin.app"
fi
