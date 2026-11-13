#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET_ARCH=arm64
if [ "$(uname -m)" != arm64 ]; then
  echo 'Native Swift ABI tests require an ARM64 macOS runner.' >&2
  exit 1
fi
xcrun swiftc -parse-as-library -D SG_CATALOG_TEST SGCatalog.swift -o build/catalog-check
build/catalog-check
xcrun clang -c PreviewContextTestCallbacks.c -o build/context-callbacks.o
xcrun swiftc -parse-as-library -D SG_PREVIEW_CONTEXT_TEST \
  -import-objc-header PreviewContextTestCallbacks.h \
  SGCatalog.swift PreviewContext.swift PreviewContextTests.swift \
  build/context-callbacks.o -o build/context-check
build/context-check
xcrun clang -c Native.S -o build/native-bridge.o
xcrun clang -c NativeBridgeTest.c -o build/native-test.o
xcrun swiftc -parse-as-library -D SG_NATIVE_BRIDGE_TEST \
  -import-objc-header NativeBridgeTest.h \
  SGCatalog.swift PreviewContext.swift NativeBridgeTests.swift \
  build/native-bridge.o build/native-test.o -o build/native-check
build/native-check
xcrun clang -fobjc-arc -fmodules -framework Foundation \
  SGRequestLogic.m RequestLogicTests.m -o build/request-check
build/request-check
bash test-session-shim.sh
xcrun clang -arch "$TARGET_ARCH" -isysroot "$SDK_PATH" -miphoneos-version-min=15.0 \
  -fobjc-arc -fmodules -O2 -Wall -Wextra -Wno-unused-parameter \
  -c Controls.m -o build/Controls.o
xcrun clang -arch "$TARGET_ARCH" -isysroot "$SDK_PATH" -miphoneos-version-min=15.0 \
  -fobjc-arc -fmodules -O2 -c SGRequestLogic.m -o build/SGRequestLogic.o
xcrun clang -arch "$TARGET_ARCH" -isysroot "$SDK_PATH" -miphoneos-version-min=15.0 \
  -c Native.S -o build/Native.o
xcrun swiftc -target arm64-apple-ios15.0 -sdk "$SDK_PATH" -O -emit-library \
  -import-objc-header Bridge.h \
  SGCatalog.swift PreviewContext.swift SessionShim.swift build/Controls.o build/SGRequestLogic.o build/Native.o \
  -Xlinker -install_name -Xlinker @rpath/SolvgramGiftControls.dylib \
  -framework Foundation -framework UIKit \
  -o build/SolvgramGiftControls.dylib
xcrun lipo -archs build/SolvgramGiftControls.dylib
xcrun vtool -show-build build/SolvgramGiftControls.dylib
xcrun nm -gU build/SolvgramGiftControls.dylib | grep -E ' _SGSessionData$'
xcrun nm -gU build/SolvgramGiftControls.dylib | grep -E ' _SGSessionDataTu$'
shasum -a 256 build/SolvgramGiftControls.dylib > build/SolvgramGiftControls.sha256
