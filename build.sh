#!/usr/bin/env bash
#
# Claude Usage Monitor 빌드 스크립트
# src/*.swift 를 컴파일해 .app 번들을 만들고 ad-hoc 코드 서명까지 수행한다.
# 옵션 --dmg 를 주면 배포용 .dmg 도 생성한다.
#
# 사용법:
#   ./build.sh           # dist/ClaudeUsageMonitor.app 생성 + 설치(~/Applications)
#   ./build.sh --dmg     # 위 + dist/ClaudeUsageMonitor.dmg 생성
#   ./build.sh --no-install   # ~/Applications 로 복사하지 않음
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ClaudeUsageMonitor"
DISPLAY_NAME="Claude Usage Monitor"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"

MAKE_DMG=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --dmg) MAKE_DMG=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 1 ;;
  esac
done

echo "▶ 컴파일 (swiftc -O)…"
rm -rf "$APP"
mkdir -p "$MACOS_DIR"
swiftc -O "$ROOT"/src/*.swift \
  -o "$MACOS_DIR/$APP_NAME" \
  -framework Cocoa -framework SwiftUI

echo "▶ 번들 구성…"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# 인앱 업데이트가 소스 위치를 알 수 있도록 빌드 시점의 절대경로를 주입한다.
# (codesign 이 Info.plist 를 봉인하므로 반드시 서명 전에 기록)
PLIST="$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c "Set :SourceRoot $ROOT" "$PLIST" 2>/dev/null; then :; else
  /usr/libexec/PlistBuddy -c "Add :SourceRoot string $ROOT" "$PLIST"
fi

echo "▶ ad-hoc 코드 서명…"
# Developer ID 인증서가 없으므로 ad-hoc(-) 서명. 배포 시 받는 사람은
# Gatekeeper 우회가 필요하다(README 참고).
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/   /'

echo "✔ 빌드 완료: $APP"

if [[ "$INSTALL" -eq 1 ]]; then
  echo "▶ ~/Applications 에 설치…"
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/$APP_NAME.app"
  echo "✔ 설치 완료: ~/Applications/$APP_NAME.app"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
  echo "▶ DMG 생성…"
  DMG="$DIST/$APP_NAME.dmg"
  STAGING="$(mktemp -d)"
  cp -R "$APP" "$STAGING/$DISPLAY_NAME.app"
  ln -s /Applications "$STAGING/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGING"
  echo "✔ DMG 완료: $DMG"
fi
