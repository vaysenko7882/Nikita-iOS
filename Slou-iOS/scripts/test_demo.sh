#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for app in /Applications/Xcode_26.5.app /Applications/Xcode.app; do
    if [[ -d "$app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$app/Contents/Developer"
        break
    fi
done
tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/slou-demo.XXXXXX")
out="${RUNNER_TEMP:-$tmp}/slou-demo-check"
if [[ ${SLOU_REVIEW:-0} == 1 ]]; then out="${RUNNER_TEMP:-$tmp}/slou-arcade-check"; fi
mkdir -p "$out"
xcrun simctl list devices available --json > "$tmp/devices.json"
read -r runtime device_type < <(python3 - "$tmp/devices.json" <<'PY'
import json, re, sys
candidates = []
for runtime, devices in json.load(open(sys.argv[1]))['devices'].items():
    if '.iOS-' not in runtime:
        continue
    match = re.search(r'\.iOS-(\d+(?:-\d+)*)', runtime)
    if not match:
        continue
    version = tuple(map(int, match.group(1).split('-')))
    for device in devices:
        if device['name'].startswith('iPhone') and device.get('isAvailable', True) and device.get('deviceTypeIdentifier'):
            name = device['name']
            candidates.append((version, 'Max' not in name and 'Plus' not in name, 'Pro' in name, name, runtime, device['deviceTypeIdentifier']))
if not candidates:
    sys.exit('No installed iPhone simulator')
print(*max(candidates)[-2:])
PY
)
sim=$(xcrun simctl create "Slou Demo ${GITHUB_RUN_ID:-local}" "$device_type" "$runtime")
echo "Testing on $device_type, $runtime"
cleanup() {
    xcrun simctl shutdown "$sim" 2>/dev/null || true
    xcrun simctl delete "$sim" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl boot "$sim"
# Boot while Xcode compiles and Homebrew installs the simulator input tool.
flags=()
if [[ ${SLOU_REVIEW:-0} == 1 ]]; then
    flags+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG SLOU_ARCADE_REVIEW')
else
    HOMEBREW_NO_AUTO_UPDATE=1 brew install cameroncooke/axe/axe > "$out/axe-install.log" 2>&1 &
    installer=$!
fi
if ! xcodebuild -project Slou.xcodeproj -scheme Slou -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$tmp/build" \
    ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" "${flags[@]+"${flags[@]}"}" build > "$out/build.log" 2>&1; then
    tail -100 "$out/build.log"
    exit 1
fi
if [[ ${SLOU_REVIEW:-0} != 1 ]]; then wait "$installer" || { cat "$out/axe-install.log"; exit 1; }; fi
xcrun simctl bootstatus "$sim" -b
xcrun simctl install "$sim" "$tmp/build/Build/Products/Debug-iphonesimulator/Slou.app"
if [[ ${SLOU_REVIEW:-0} == 1 ]]; then
    python3 -u scripts/review_arcade.py "$sim" "$out" "$tmp"
    exit
fi
xcrun simctl launch "$sim" app.slou.watch -server ""
python3 -u scripts/demo_walkthrough.py "$sim" "$out"
