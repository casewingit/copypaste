#!/bin/bash
# 빌드해서 ~/Applications 에 설치하고, 로그인할 때 자동으로 실행되게 등록한다.
# 두 Mac 모두에서 한 번씩 실행하면 된다.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.copypaste.agent
APP="$HOME/Applications/Copypaste.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 브라우저로 받은 zip에는 격리(quarantine) 표시가 붙어 실행이 막힐 수 있어 먼저 지운다.
xattr -dr com.apple.quarantine . 2>/dev/null || true

# 미리 빌드된 앱이 소스보다 최신이면(릴리스 zip) 그대로 쓰고, 아니면 소스에서 빌드한다.
# /usr/bin/swiftc 는 개발 도구가 없어도 껍데기로 존재하므로 xcrun 으로 실제 컴파일러를 확인한다.
if [ -d build/Copypaste.app ] && [ build/Copypaste.app/Contents/MacOS/copypaste -nt Sources/main.swift ]; then
    echo "미리 빌드된 앱을 사용합니다."
elif xcrun -f swiftc >/dev/null 2>&1; then
    bash build.sh
else
    echo "Swift 컴파일러가 없습니다. GitHub Releases의 copypaste-installer.zip 을 받아 설치하거나," >&2
    echo "'xcode-select --install' 후 다시 실행하세요." >&2
    exit 1
fi

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
cp -R build/Copypaste.app "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/copypaste</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/copypaste.log</string>
</dict>
</plist>
EOF

if ! launchctl bootstrap "gui/$UID" "$PLIST"; then
    echo "자동 실행 등록에 실패했습니다. 위 오류 메시지를 확인하세요." >&2
    exit 1
fi
echo "설치 완료. 메뉴 막대에 링크 아이콘이 보이면 Finder에서 파일을 복사해 보세요."
echo "로그: ~/Library/Logs/copypaste.log"
