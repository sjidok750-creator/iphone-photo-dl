#!/bin/bash
# 소스에서 '아이폰 사진 받기.app' 을 만든다.
#   bash build.sh            이 Mac 에 맞는 것만 (Xcode 명령줄 도구 필요: xcode-select --install)
#   bash build.sh universal  Intel + Apple Silicon 한 파일 (빌드 서버용)
# 결과: build/아이폰 사진 받기.app  (터미널용 실행 파일은 그 안의 Contents/MacOS/iphone-photo-dl)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-native}"
OUT="build"
APP_NAME="아이폰 사진 받기"
APP="$OUT/$APP_NAME.app"
BIN_NAME="iphone-photo-dl"
BUNDLE_ID="io.github.sjidok750-creator.iphone-photo-dl"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Core.swift)
mkdir -p "$OUT"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc 가 없습니다. 터미널에서 'xcode-select --install' 로 명령줄 도구를 먼저 설치하세요." >&2
  exit 1
fi

FLAGS="-O -module-name iphone_photo_dl"
# Swift 5.7 이상은 쓰지 않는 표준 모듈을 자동으로 끌어오는데, 그 라이브러리가 옛 macOS(10.15)에는 없다.
SWIFT_VER=$(swiftc --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -n 1)
SWIFT_MAJOR=${SWIFT_VER%% *}
SWIFT_MINOR=${SWIFT_VER##* }
if [ -n "$SWIFT_MAJOR" ] && { [ "$SWIFT_MAJOR" -gt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -ge 7 ]; }; }; then
  FLAGS="$FLAGS -Xfrontend -disable-implicit-string-processing-module-import -Xfrontend -disable-implicit-concurrency-module-import"
fi

build_one() { # $1 = target triple, $2 = output
  # shellcheck disable=SC2086
  swiftc $FLAGS -target "$1" -o "$2" Sources/*.swift
}

if [ "$MODE" = "universal" ]; then
  build_one x86_64-apple-macos10.15 "$OUT/$BIN_NAME-x86_64"
  build_one arm64-apple-macos11 "$OUT/$BIN_NAME-arm64"
  lipo -create -output "$OUT/$BIN_NAME" "$OUT/$BIN_NAME-x86_64" "$OUT/$BIN_NAME-arm64"
  rm -f "$OUT/$BIN_NAME-x86_64" "$OUT/$BIN_NAME-arm64"
else
  case "$(uname -m)" in
    arm64) build_one arm64-apple-macos11 "$OUT/$BIN_NAME" ;;
    *)     build_one x86_64-apple-macos10.15 "$OUT/$BIN_NAME" ;;
  esac
fi
chmod +x "$OUT/$BIN_NAME"

# --- 앱 묶음 ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

ICON_KEY=""
if swift tools/make_icon.swift "$OUT/icon.png" >/dev/null 2>&1; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
  fi
else
  echo "(아이콘을 만들지 못해 기본 아이콘으로 둡니다)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  $ICON_KEY
</dict>
</plist>
PLIST

# Apple Silicon 은 서명(애드혹이라도)이 없으면 실행을 막는다.
codesign --force --sign - "$OUT/$BIN_NAME" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "빌드 완료: $APP (버전 $VERSION)"
