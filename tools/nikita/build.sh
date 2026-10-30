#!/bin/bash
set -euo pipefail
nikita_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$nikita_root"
if [ "$(uname -s)" != Darwin ]; then
  echo "This full Swift/iOS build needs macOS and the Xcode version in versions.json." >&2
  exit 2
fi
if [ ! -f build-system/nikita-local-configuration.json ]; then
  echo "Run tools/nikita/configure.py with your own Telegram API credentials first." >&2
  exit 2
fi
nikita_cache="${RUNNER_TEMP:-$nikita_root/build}/nikita-bazel-cache"
# disable_legacy_signing is supported by the pinned rules_apple implementation.
python3 build-system/Make/Make.py \
  --cacheDir="$nikita_cache" \
  --bazelArguments="--//Telegram:disableProvisioningProfiles --//Telegram:disableExtensions --//Telegram:disableAppGroups --features=disable_legacy_signing --jobs=2 --local_resources=memory=4096" \
  build \
  --configurationPath=build-system/nikita-local-configuration.json \
  --xcodeManagedCodesigning \
  --apsEnvironment=development \
  --configuration=release_arm64 \
  --buildNumber="${GITHUB_RUN_NUMBER:-1}"
# Use the actual current Bazel output, never the possibly stale archive-root folder.
python3 tools/nikita/validate_ipa.py bazel-bin/Telegram/Telegram.ipa
