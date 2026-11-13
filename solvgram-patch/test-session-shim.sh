#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -fobjc-arc -fmodules -c SessionShimTestMocks.m -o build/session-mocks.o
xcrun clang -fobjc-arc -fmodules -c SGRequestLogic.m -o build/session-logic.o
xcrun swiftc -target arm64-apple-macos12.0 -parse-as-library -emit-library -module-name SGSessionShim \
  -import-objc-header SessionShimTestMocks.h \
  SessionShim.swift build/session-mocks.o build/session-logic.o \
  -framework Foundation -o build/SessionShim-check.dylib
xcrun nm -gU build/SessionShim-check.dylib | grep -E ' _SGSessionData$'
xcrun nm -gU build/SessionShim-check.dylib | grep -E ' _SGSessionDataTu$'
xcrun swiftc -target arm64-apple-macos12.0 -parse-as-library -module-name SGSessionShimTests \
  -import-objc-header SessionShimTestMocks.h \
  SessionShim.swift SessionShimTests.swift build/session-mocks.o build/session-logic.o \
  -framework Foundation -o build/session-shim-check
build/session-shim-check
