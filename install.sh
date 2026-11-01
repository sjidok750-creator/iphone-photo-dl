#!/bin/bash
# iphone-photo-dl 설치
#   curl -fsSL https://raw.githubusercontent.com/sjidok750-creator/iphone-photo-dl/main/install.sh | bash
#
# 하는 일
#   1) GitHub 릴리스에서 실행 파일을 받아 ~/.iphone-photo-dl/bin 에 둔다
#      (릴리스를 못 받으면, Xcode 명령줄 도구가 있을 때 소스에서 빌드)
#   2) 바탕화면에 '아이폰 사진 받기.command' (더블클릭 실행) 를 만든다
#   3) 터미널에서 'iphone-photo-dl' 로도 쓸 수 있게 한다(가능할 때)
set -euo pipefail

REPO="sjidok750-creator/iphone-photo-dl"
ASSET="iphone-photo-dl-macos.tar.gz"
APP_DIR="$HOME/.iphone-photo-dl"
BIN_DIR="$APP_DIR/bin"
BIN="$BIN_DIR/iphone-photo-dl"
LAUNCHER_NAME="아이폰 사진 받기.command"

say() { printf '%s\n' "$*"; }
die() { printf '설치 실패: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS 에서만 설치할 수 있습니다."

# macOS 10.15 (Catalina) 이상
VER=$(sw_vers -productVersion)
MAJOR=${VER%%.*}
REST=${VER#*.}
MINOR=${REST%%.*}
if [ "$MAJOR" -lt 11 ] && [ "$MINOR" -lt 15 ]; then
  die "macOS $VER 입니다. 10.15(Catalina) 이상이 필요합니다. 2013년 맥북프로는 시스템 환경설정 > 소프트웨어 업데이트로 Catalina 이상을 설치할 수 있습니다."
fi

mkdir -p "$BIN_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "1/3 프로그램 받는 중…"
# IPHONE_PHOTO_DL_ASSET_URL: 다른 곳의 실행 파일 묶음으로 설치(빌드 서버 시험용, file:// 가능)
ASSET_URL="${IPHONE_PHOTO_DL_ASSET_URL:-https://github.com/$REPO/releases/latest/download/$ASSET}"
if curl -fsSL --retry 3 -o "$TMP/$ASSET" "$ASSET_URL" \
   && tar -xzf "$TMP/$ASSET" -C "$TMP" && [ -f "$TMP/iphone-photo-dl" ]; then
  cp "$TMP/iphone-photo-dl" "$BIN"
elif command -v swiftc >/dev/null 2>&1; then
  say "   릴리스를 받지 못해 소스에서 빌드합니다…"
  curl -fsSL --retry 3 -o "$TMP/src.tar.gz" "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
    || die "소스를 받지 못했습니다. 인터넷 연결을 확인하세요."
  mkdir -p "$TMP/src"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components 1
  bash "$TMP/src/build.sh" >/dev/null
  cp "$TMP/src/build/iphone-photo-dl" "$BIN"
else
  die "프로그램을 받지 못했습니다. 인터넷 연결을 확인하고 다시 실행하세요."
fi
chmod +x "$BIN"
xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
"$BIN" --version >/dev/null 2>&1 || die "받은 프로그램이 이 Mac 에서 실행되지 않습니다 ($("$BIN" --version 2>&1 | head -n 1))."
say "   $("$BIN" --version)"

say "2/3 바탕화면에 '$LAUNCHER_NAME' 만드는 중…"
mkdir -p "$HOME/Pictures/iPhone"
LAUNCHER_PATH="$HOME/Desktop/$LAUNCHER_NAME"
if ! touch "$LAUNCHER_PATH" 2>/dev/null; then
  # 바탕화면 접근이 막혀 있으면 설치 폴더에 둔다.
  LAUNCHER_PATH="$APP_DIR/$LAUNCHER_NAME"
fi
cat > "$LAUNCHER_PATH" <<'LAUNCHER'
#!/bin/bash
# 더블클릭하면 아이폰 사진을 받습니다. (iphone-photo-dl)
BIN="$HOME/.iphone-photo-dl/bin/iphone-photo-dl"
LAST="$HOME/.iphone-photo-dl/last_folder"
clear
if [ ! -x "$BIN" ]; then
  echo "프로그램이 없습니다. 다시 설치하세요:"
  echo "  curl -fsSL https://raw.githubusercontent.com/sjidok750-creator/iphone-photo-dl/main/install.sh | bash"
  read -r -n 1 -s -p "아무 키나 누르면 닫습니다."
  exit 1
fi
DEFAULT="$HOME/Pictures/iPhone"
if [ -f "$LAST" ] && [ -d "$(cat "$LAST")" ]; then DEFAULT="$(cat "$LAST")"; fi
mkdir -p "$DEFAULT"
echo "사진을 받을 폴더를 고르세요. (그 안에 연/월 폴더로 정리됩니다)"
DEST=$(osascript \
  -e 'on run argv' \
  -e 'set d to (POSIX file (item 1 of argv)) as alias' \
  -e 'return POSIX path of (choose folder with prompt "아이폰 사진을 받을 폴더를 고르세요" default location d)' \
  -e 'end run' "$DEFAULT" 2>/dev/null)
if [ -z "$DEST" ]; then
  echo "취소했습니다."
  exit 0
fi
printf '%s' "$DEST" > "$LAST"
echo
"$BIN" --open "$DEST"
echo
read -r -n 1 -s -p "아무 키나 누르면 이 창을 닫습니다."
echo
LAUNCHER
chmod +x "$LAUNCHER_PATH"
xattr -d com.apple.quarantine "$LAUNCHER_PATH" 2>/dev/null || true

say "3/3 터미널 명령 연결…"
LINKED=""
for d in /usr/local/bin /opt/homebrew/bin; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    ln -sf "$BIN" "$d/iphone-photo-dl" && LINKED="$d/iphone-photo-dl" && break
  fi
done

say ""
say "설치 끝."
say "  · 더블클릭 실행: $LAUNCHER_PATH"
if [ -n "$LINKED" ]; then
  say "  · 터미널: iphone-photo-dl --help"
else
  say "  · 터미널: $BIN --help"
fi
say ""
say "아이폰을 케이블로 연결하고 잠금을 푼 뒤 '$LAUNCHER_NAME' 를 더블클릭하세요."
say "속도를 높이려면 아이폰 설정 > 사진 > 'MAC 또는 PC로 전송' 을 '원본 유지' 로 두세요."
