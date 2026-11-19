#!/bin/bash
# Сборка неподписанного Slou.ipa на своём Mac: bash scripts/build_ipa.sh
# Нужен Xcode (для Liquid Glass — Xcode 26 или новее).
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build Payload Slou.ipa
xcodebuild -project Slou.xcodeproj -target Slou -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
test -d build/Release-iphoneos/Slou.app || { echo "Сборка не удалась — открой Slou.xcodeproj в Xcode и посмотри ошибки"; exit 1; }
mkdir Payload && cp -R build/Release-iphoneos/Slou.app Payload/ && zip -qry Slou.ipa Payload && rm -rf Payload
echo "Готово: $PWD/Slou.ipa — подпиши его через Sideloadly / AltStore / свой сертификат"
