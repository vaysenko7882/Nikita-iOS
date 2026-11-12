#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
BUILD_ROOT="$PWD/build"
mkdir -p "$BUILD_ROOT"
xcodebuild -version
xcrun swiftc Autismex/Models.swift scripts/validate-models.swift -o "$BUILD_ROOT/validate-models"
"$BUILD_ROOT/validate-models" scripts/demo-state.json
xcodebuild \
  -project Autismex.xcodeproj \
  -scheme Autismex \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_ROOT/Autismex.xcarchive" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  archive
APP="$BUILD_ROOT/Autismex.xcarchive/Products/Applications/Autismex.app"
test -d "$APP"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist")"
test -f "$APP/$EXECUTABLE"
xcrun lipo "$APP/$EXECUTABLE" -verify_arch arm64
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist"
rm -rf "$BUILD_ROOT/Payload"
mkdir -p "$BUILD_ROOT/Payload"
ditto "$APP" "$BUILD_ROOT/Payload/Autismex.app"
find "$BUILD_ROOT/Payload" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
find "$BUILD_ROOT/Payload" -name 'embedded.mobileprovision' -type f -delete
rm -f "$BUILD_ROOT/Autismex-unsigned.ipa"
( cd "$BUILD_ROOT" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload Autismex-unsigned.ipa )
unzip -t "$BUILD_ROOT/Autismex-unsigned.ipa"
shasum -a 256 "$BUILD_ROOT/Autismex-unsigned.ipa" > "$BUILD_ROOT/Autismex-unsigned.sha256"
printf 'commit=%s\nunsigned=true\nrequires_resigning=true\n' "${GITHUB_SHA:-local}" > "$BUILD_ROOT/build-info.txt"
echo "Built $BUILD_ROOT/Autismex-unsigned.ipa"
