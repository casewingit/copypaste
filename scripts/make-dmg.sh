#!/bin/bash
# 끌어다 놓아 설치하는 디스크 이미지 dist/Copypaste-<버전>.dmg 를 만든다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
[ -d build/Copypaste.app ] || bash build.sh
OUT="dist/Copypaste-$VERSION.dmg"
WORK=$(mktemp -d)
VOL="Copypaste"
mkdir -p dist "$WORK/src/.background"
cp -Rp build/Copypaste.app "$WORK/src/"
ln -s /Applications "$WORK/src/Applications"
cp Resources/dmg-background.png "$WORK/src/.background/background.png"

# 창 모양을 꾸미려면 쓰기 가능한 이미지로 먼저 만들어 Finder로 배치한 뒤 압축본으로 바꾼다.
hdiutil create -quiet -srcfolder "$WORK/src" -volname "$VOL" -fs HFS+ -format UDRW "$WORK/rw.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
# Finder가 응답하지 않는 환경(화면 잠김, 원격 빌드 등)에서도 멈추지 않도록 시간 제한을 둔다.
osascript >/dev/null 2>&1 <<OSA &
with timeout of 15 seconds
    tell application "Finder"
        tell disk "$VOL"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 860, 520}
            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 112
            set text size of opts to 13
            set background picture of opts to file ".background:background.png"
            set position of item "Copypaste.app" of container window to {170, 175}
            set position of item "Applications" of container window to {490, 175}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
OSA
OSA_PID=$!
( sleep 45; kill "$OSA_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCH=$!
if wait "$OSA_PID"; then STYLED=1; else STYLED=0; echo "주의: Finder로 창 모양을 꾸미지 못해 기본 모양으로 만듭니다." >&2; fi
{ kill "$WATCH" && wait "$WATCH"; } 2>/dev/null || true
sync
hdiutil detach -quiet "$MOUNT"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$WORK"
echo "완성: $OUT"
shasum -a 256 "$OUT"
