#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Payload/NaSvyazi.app build/Assets.xcassets
APP_DIR="$PWD/build/Payload/NaSvyazi.app"
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc App/AudioPacketCodec.swift Tests/AudioPacketCodecCheck.swift -o build/codec-check
build/codec-check
xcrun swift scripts/GenerateIcon.swift "$PWD/build/Assets.xcassets"
xcrun actool build/Assets.xcassets --compile "$APP_DIR" --platform iphoneos --minimum-deployment-target 16.0 --app-icon AppIcon --output-partial-info-plist build/icon-info.plist --target-device iphone
xcrun swiftc -swift-version 5 -target arm64-apple-ios16.0 -sdk "$SDK_PATH" -parse-as-library -O \
  App/*.swift -o "$APP_DIR/NaSvyazi" \
  -framework SwiftUI -framework UIKit -framework AVFoundation -framework MultipeerConnectivity -framework PushToTalk -framework CryptoKit \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks
python3 scripts/write_info.py "$APP_DIR" build/icon-info.plist
chmod 755 "$APP_DIR/NaSvyazi"
cd build
zip -qr ../NaSvyazi-unsigned.ipa Payload
cd ..
shasum -a 256 NaSvyazi-unsigned.ipa > NaSvyazi-unsigned.sha256
xcrun vtool -show-build "$APP_DIR/NaSvyazi"
