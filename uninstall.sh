#!/bin/bash
# 앱, 자동 실행 등록, tailscale serve 설정, 공유 목록을 모두 지운다.
set -uo pipefail

LABEL=com.copypaste.agent
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Copypaste.app" "$HOME/Library/Application Support/copypaste"

TS=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
"$TS" serve --https="${COPYPASTE_PORT:-8765}" off 2>/dev/null
echo "제거 완료."
