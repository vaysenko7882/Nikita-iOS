#!/bin/bash
# Сборка неподписанного Autismex-unsigned.ipa (как прежний файл) — для подписи
# через Sideloadly / AltStore / TrollStore или своим сертификатом.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build Payload Autismex-unsigned.ipa

xcodebuild \
  -project Autismex.xcodeproj \
  -scheme Autismex \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

mkdir Payload
cp -R build/Build/Products/Release-iphoneos/Autismex.app Payload/
for binary in Payload/Autismex.app/Autismex Payload/Autismex.app/PlugIns/*.appex/*; do
  if [ -f "$binary" ] && file "$binary" | grep -q 'Mach-O.*executable'; then
    xcrun lipo "$binary" -verify_arch arm64
  fi
done
find Payload -name '_CodeSignature' -type d -prune -exec rm -rf {} +
find Payload -name 'embedded.mobileprovision' -type f -delete
zip -qry Autismex-unsigned.ipa Payload
unzip -t Autismex-unsigned.ipa
mv Autismex-unsigned.ipa Autismex-2.0-unsigned.ipa
shasum -a 256 Autismex-2.0-unsigned.ipa > Autismex-2.0-unsigned.sha256
printf 'commit=%s\nunsigned=true\nrequires_resigning=true\n' "${GITHUB_SHA:-local}" > build-info.txt
rm -rf Payload
echo "Готово: $(pwd)/Autismex-2.0-unsigned.ipa"
