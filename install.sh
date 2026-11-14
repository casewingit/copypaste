#!/bin/bash
# 빌드해서 ~/Applications 에 설치하고, 로그인할 때 자동으로 실행되게 등록한다.
# 두 Mac 모두에서 한 번씩 실행하면 된다.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.copypaste.agent
APP="$HOME/Applications/Copypaste.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 사전 점검: Tailscale이 있어야 한다.
TS=""
for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale; do
    [ -x "$c" ] && TS="$c" && break
done
if [ -z "$TS" ]; then
    echo "Tailscale을 찾을 수 없습니다. https://tailscale.com/download 에서 설치하고 로그인한 뒤 다시 실행하세요." >&2
    exit 1
fi

# 포트 등을 바꾸려면: COPYPASTE_PORT=9000 bash install.sh
ENVXML=""
for v in COPYPASTE_PORT COPYPASTE_LOCAL_PORT COPYPASTE_TTL_HOURS; do
    val="${!v:-}"
    if [ -n "$val" ]; then
        case "$val" in *[!0-9.]*) echo "$v 는 숫자여야 합니다." >&2; exit 1 ;; esac
        ENVXML="$ENVXML<key>$v</key><string>$val</string>"
    fi
done

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
    <key>EnvironmentVariables</key><dict>$ENVXML</dict>
    <key>RunAtLoad</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
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

# 앱이 Tailscale에 연결될 때까지 잠깐 기다렸다가 결과를 알려 준다.
LOG="$HOME/Library/Logs/copypaste.log"
START=$(wc -l < "$LOG" 2>/dev/null || echo 0)
for _ in $(seq 1 15); do
    sleep 1
    NEW=$(tail -n +"$((START + 1))" "$LOG" 2>/dev/null || true)
    if echo "$NEW" | grep -q "준비 완료"; then
        echo "설치 완료. Finder에서 파일을 복사하면 링크가 클립보드에 함께 들어갑니다."
        echo "$NEW" | grep "준비 완료" | tail -1 | sed 's/.*준비 완료: /공유 목록: /'
        exit 0
    fi
    if echo "$NEW" | grep -q "사용 불가" && ! echo "$NEW" | grep -q "확인 중"; then break; fi
done
echo "앱은 설치됐지만 아직 링크를 만들 수 없습니다:" >&2
echo "$NEW" | grep -E "사용 불가|serve 실패" | tail -2 | sed 's/^\[[^]]*\] /  /' >&2
echo "문제를 해결하면 30초 안에 자동으로 다시 시도합니다. 메뉴 막대의 ⚠︎ 아이콘에서도 원인을 볼 수 있습니다." >&2
exit 1
