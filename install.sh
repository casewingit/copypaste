#!/bin/bash
# 빌드해서 ~/Applications 에 설치하고, 로그인할 때 자동으로 실행되게 등록한다.
# 두 Mac 모두에서 한 번씩 실행하면 된다.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.copypaste.agent
APP="$HOME/Applications/Copypaste.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 소스에서 빌드한다. 컴파일러가 없는 Mac에서는 함께 받은 build/Copypaste.app 을 그대로 쓴다.
if command -v swiftc >/dev/null 2>&1; then
    ./build.sh
elif [ ! -d build/Copypaste.app ]; then
    echo "swiftc가 없고 미리 빌드된 앱도 없습니다. 'xcode-select --install' 후 다시 실행하세요." >&2
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

launchctl bootstrap "gui/$UID" "$PLIST"
echo "설치 완료. 메뉴 막대에 링크 아이콘이 보이면 Finder에서 파일을 복사해 보세요."
echo "로그: ~/Library/Logs/copypaste.log"
