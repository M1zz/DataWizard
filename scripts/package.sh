#!/bin/bash
# 배포용 .dmg 만들기 — Release 빌드 → 서명 → 끌어다 놓는 설치 이미지.
#
#   ./scripts/package.sh            (있는 서명 인증서로)
#   ./scripts/package.sh "Developer ID Application: 이름 (팀ID)"
#
# Developer ID 인증서로 서명하면 공증(notarize)까지 붙일 수 있고, 그때부터
# 받는 사람이 그냥 더블클릭으로 열 수 있다. 개발용 인증서로 만들면
# 처음 한 번은 오른쪽 클릭 → 열기가 필요하다.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | grep "Developer ID Application" | head -1 \
             | sed 's/.*"\(.*\)"/\1/' || true)
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | head -1 \
             | sed -n 's/.*"\(.*\)"/\1/p' || true)
fi
echo "서명: ${IDENTITY:-(없음 — ad-hoc)}"

echo "→ Release 빌드"
xcodebuild -project DataWizard.xcodeproj -scheme DataWizard -configuration Release \
           -derivedDataPath build/release build >/dev/null

APP="build/release/Build/Products/Release/DataWizard.app"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [ -n "$IDENTITY" ]; then
  echo "→ 서명"
  codesign --force --deep --options runtime \
           --entitlements DataWizard/DataWizard.entitlements \
           --sign "$IDENTITY" "$APP"
  codesign --verify --verbose=1 "$APP"
fi

echo "→ 설치 이미지 만들기"
STAGE=$(mktemp -d)/DataWizard
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/데이터 마법사.app"
ln -s /Applications "$STAGE/Applications"
cp packaging/설치안내.txt "$STAGE/처음 열 때 읽어 주세요.txt"

mkdir -p dist
hdiutil create -volname "데이터 마법사" -srcfolder "$STAGE" -ov -format UDZO -quiet \
               "dist/DataWizard-$VER.dmg"
rm -rf "$(dirname "$STAGE")"

echo "완성: dist/DataWizard-$VER.dmg ($(du -h "dist/DataWizard-$VER.dmg" | cut -f1))"
if ! spctl -a -vv "$APP" >/dev/null 2>&1; then
  echo
  echo "참고: 애플 공증을 받지 않은 앱입니다 — 받는 사람은 처음 한 번"
  echo "      오른쪽 클릭 → 열기 로 열어야 합니다 (안내문을 이미지에 넣어 뒀습니다)."
  echo "      Developer ID 인증서가 있으면 공증까지 붙일 수 있습니다:"
  echo "      xcrun notarytool submit dist/DataWizard-$VER.dmg --apple-id … --team-id … --wait"
  echo "      xcrun stapler staple dist/DataWizard-$VER.dmg"
fi
