#!/bin/bash
# 소스에서 빌드해 /Applications 에 설치하고 실행한다. (일반 사용자는 Releases의 DMG를 쓰면 된다)
set -euo pipefail
cd "$(dirname "$0")"

bash build.sh
pkill -f "Copypaste.app/Contents/MacOS/copypaste" 2>/dev/null || true
rm -rf /Applications/Copypaste.app
cp -Rp build/Copypaste.app /Applications/Copypaste.app
open /Applications/Copypaste.app
echo "설치 완료: /Applications/Copypaste.app (메뉴 막대의 링크 아이콘을 확인하세요)"
