#!/bin/bash
# build/Copypaste.app 을 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Copypaste.app
rm -rf "./$APP"
mkdir -p "$APP/Contents/MacOS"

# Apple Silicon과 Intel Mac 어디서나 돌도록 유니버설로 만든다.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/main.swift -o "build/copypaste-$arch"
done
lipo -create build/copypaste-arm64 build/copypaste-x86_64 -output "$APP/Contents/MacOS/copypaste"
rm build/copypaste-arm64 build/copypaste-x86_64

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.copypaste.agent</string>
    <key>CFBundleName</key><string>Copypaste</string>
    <key>CFBundleExecutable</key><string>copypaste</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "빌드 완료: $APP"
