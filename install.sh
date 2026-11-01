#!/bin/bash
# '아이폰 사진 받기' 설치 (같은 명령으로 업데이트도 됩니다)
#   curl -fsSL https://raw.githubusercontent.com/sjidok750-creator/iphone-photo-dl/main/install.sh | bash
#
# 하는 일
#   1) GitHub 릴리스에서 앱을 받아 응용 프로그램 폴더에 둔다
#      (릴리스를 못 받으면, Xcode 명령줄 도구가 있을 때 소스에서 빌드)
#   2) 바탕화면에 바로가기를 두고, 0.9 의 '아이폰 사진 받기.command' 는 지운다
#   3) 터미널 명령 iphone-photo-dl 도 연결하고, 앱을 연다
set -euo pipefail

REPO="sjidok750-creator/iphone-photo-dl"
ASSET="iPhonePhotoDL-app.zip"
APP_NAME="아이폰 사진 받기"
BIN_NAME="iphone-photo-dl"
STATE_DIR="$HOME/.iphone-photo-dl"

say() { printf '%s\n' "$*"; }
die() { printf '설치 실패: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS 에서만 설치할 수 있습니다."

VER=$(sw_vers -productVersion)
MAJOR=${VER%%.*}
REST=${VER#*.}
MINOR=${REST%%.*}
if [ "$MAJOR" -lt 11 ] && [ "$MINOR" -lt 15 ]; then
  die "macOS $VER 입니다. 10.15(Catalina) 이상이 필요합니다."
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "1/3 앱 받는 중…"
# IPHONE_PHOTO_DL_ASSET_URL: 다른 곳의 앱 묶음으로 설치(빌드 서버 시험용, file:// 가능)
ASSET_URL="${IPHONE_PHOTO_DL_ASSET_URL:-https://github.com/$REPO/releases/latest/download/$ASSET}"
NEW_APP=""
if curl -fsSL --retry 3 -o "$TMP/$ASSET" "$ASSET_URL"; then
  mkdir -p "$TMP/x"
  ditto -x -k "$TMP/$ASSET" "$TMP/x"
  NEW_APP=$(find "$TMP/x" -maxdepth 2 -name "*.app" -type d | head -n 1)
fi
if [ -z "$NEW_APP" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    say "   릴리스를 받지 못해 소스에서 빌드합니다 (몇 분 걸립니다)…"
    curl -fsSL --retry 3 -o "$TMP/src.tar.gz" "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
      || die "소스를 받지 못했습니다. 인터넷 연결을 확인하세요."
    mkdir -p "$TMP/src"
    tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components 1
    bash "$TMP/src/build.sh" >/dev/null
    NEW_APP="$TMP/src/build/$APP_NAME.app"
  else
    die "앱을 받지 못했습니다. 인터넷 연결을 확인하고 다시 실행하세요."
  fi
fi
[ -x "$NEW_APP/Contents/MacOS/$BIN_NAME" ] || die "받은 앱이 올바르지 않습니다."

# 응용 프로그램 폴더 (쓸 수 없으면 내 응용 프로그램 폴더)
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST_APP="$DEST_DIR/$APP_NAME.app"

# 열려 있으면 닫고 바꾼다 (업데이트)
if pgrep -f "$APP_NAME.app/Contents/MacOS/$BIN_NAME" >/dev/null 2>&1; then
  osascript -e 'tell application id "io.github.sjidok750-creator.iphone-photo-dl" to quit' >/dev/null 2>&1 || true
fi
for _ in 1 2 3 4 5; do
  pgrep -f "$APP_NAME.app/Contents/MacOS/$BIN_NAME" >/dev/null 2>&1 || break
  sleep 1
done
rm -rf "$DEST_APP"
ditto "$NEW_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
"$DEST_APP/Contents/MacOS/$BIN_NAME" --version >/dev/null 2>&1 || die "앱이 이 Mac 에서 실행되지 않습니다."
say "   $("$DEST_APP/Contents/MacOS/$BIN_NAME" --version) → $DEST_APP"

say "2/3 바탕화면 바로가기…"
OLD_LAUNCHER="$HOME/Desktop/아이폰 사진 받기.command"
[ -f "$OLD_LAUNCHER" ] && rm -f "$OLD_LAUNCHER"
[ -f "$STATE_DIR/아이폰 사진 받기.command" ] && rm -f "$STATE_DIR/아이폰 사진 받기.command"
SHORTCUT="$HOME/Desktop/$APP_NAME"
if [ -d "$HOME/Desktop" ]; then
  if [ -L "$SHORTCUT" ] || [ ! -e "$SHORTCUT" ]; then
    ln -sfn "$DEST_APP" "$SHORTCUT" 2>/dev/null || true
  fi
fi

say "3/3 터미널 명령 연결…"
mkdir -p "$STATE_DIR/bin"
rm -f "$STATE_DIR/bin/$BIN_NAME"
ln -s "$DEST_APP/Contents/MacOS/$BIN_NAME" "$STATE_DIR/bin/$BIN_NAME"
for d in /usr/local/bin /opt/homebrew/bin; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    ln -sf "$DEST_APP/Contents/MacOS/$BIN_NAME" "$d/$BIN_NAME" && break
  fi
done

say ""
say "설치 끝. '$APP_NAME' 앱을 엽니다."
say "  · 다음부터: 바탕화면 또는 응용 프로그램 폴더의 '$APP_NAME' 더블클릭"
say "  · 아이폰을 케이블로 연결하고 잠금을 풀면 저절로 받기 시작합니다."
say "  · 빠르게 받으려면 아이폰 설정 > 사진 > 'Mac 또는 PC로 전송' 을 '원본 유지' 로 두세요."
if [ -z "${IPHONE_PHOTO_DL_NO_LAUNCH:-}" ]; then
  open "$DEST_APP" || true
fi
