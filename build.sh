#!/bin/bash
# build/Copypaste.app 을 만든다. (Xcode 명령줄 도구 필요)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
APP=build/Copypaste.app
rm -rf "./$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Apple Silicon과 Intel Mac 어디서나 돌도록 유니버설로 만든다.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/main.swift -o "build/copypaste-$arch"
done
lipo -create build/copypaste-arm64 build/copypaste-x86_64 -output "$APP/Contents/MacOS/copypaste"
rm build/copypaste-arm64 build/copypaste-x86_64
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.copypaste.agent</string>
    <key>CFBundleName</key><string>Copypaste</string>
    <key>CFBundleDisplayName</key><string>Copypaste</string>
    <key>CFBundleExecutable</key><string>copypaste</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# 개발자 인증서가 없으므로 임시(ad-hoc) 서명. SIGN_ID 로 Developer ID를 주면 그것으로 서명한다.
codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
echo "빌드 완료: $APP ($VERSION)"
