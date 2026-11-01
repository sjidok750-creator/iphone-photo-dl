#!/bin/bash
# 소스에서 iphone-photo-dl 을 빌드한다.
#   ./build.sh            이 Mac 에 맞는 것만 (Xcode 명령줄 도구 필요: xcode-select --install)
#   ./build.sh universal  Intel + Apple Silicon 한 파일 (빌드 서버용)
# 결과: build/iphone-photo-dl
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-native}"
OUT="build"
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
  build_one x86_64-apple-macos10.15 "$OUT/iphone-photo-dl-x86_64"
  build_one arm64-apple-macos11 "$OUT/iphone-photo-dl-arm64"
  lipo -create -output "$OUT/iphone-photo-dl" "$OUT/iphone-photo-dl-x86_64" "$OUT/iphone-photo-dl-arm64"
  rm -f "$OUT/iphone-photo-dl-x86_64" "$OUT/iphone-photo-dl-arm64"
else
  case "$(uname -m)" in
    arm64) build_one arm64-apple-macos11 "$OUT/iphone-photo-dl" ;;
    *)     build_one x86_64-apple-macos10.15 "$OUT/iphone-photo-dl" ;;
  esac
fi

# Apple Silicon 은 서명(애드혹이라도)이 없으면 실행을 막는다.
codesign --force --sign - "$OUT/iphone-photo-dl" >/dev/null 2>&1 || true
chmod +x "$OUT/iphone-photo-dl"
echo "빌드 완료: $OUT/iphone-photo-dl"
