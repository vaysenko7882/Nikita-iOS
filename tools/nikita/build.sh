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
python3 tools/nikita/rebrand.py
# The pinned Apple rules skip signing with disable_legacy_signing, but still
# unconditionally embed a device profile. Skip that partial for this unsigned build.
python3 - <<'NIKITA_UNSIGNED'
from pathlib import Path
import subprocess
root = Path('build-system/bazel-rules/rules_apple')
expected = '485016eb5b0948cc17307064e7977a6d68e94046'
if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != expected:
    raise SystemExit('Unsigned rule adjustment requires the pinned rules_apple revision.')
p = root / 'apple/internal/ios_rules.bzl'
s = p.read_text()
a = s.index('def _ios_application_impl(')
b = s.index('\ndef ', a + 1)
part = s[a:b]
old = 'if platform_prerequisites.platform.is_device:\n        processor_partials.append(\n            partials.provisioning_profile_partial('
new = 'if platform_prerequisites.platform.is_device and "disable_legacy_signing" not in features:\n        processor_partials.append(\n            partials.provisioning_profile_partial('
if part.count(old) == 1:
    s = s[:a] + part.replace(old, new) + s[b:]
    p.write_text(s)
elif part.count(new) != 1:
    raise SystemExit('Pinned provisioning profile rule has changed; refusing an unchecked patch.')
NIKITA_UNSIGNED
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
