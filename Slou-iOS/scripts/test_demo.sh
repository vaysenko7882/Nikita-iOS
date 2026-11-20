#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for app in /Applications/Xcode_27*.app /Applications/Xcode_26*.app /Applications/Xcode.app; do
    if [[ -d "$app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$app/Contents/Developer"
        break
    fi
done
tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/slou-demo.XXXXXX")
out="${RUNNER_TEMP:-$tmp}/slou-demo-check"
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
rec=""
cleanup() {
    if [[ -n "$rec" ]]; then kill -INT "$rec" 2>/dev/null || true; fi
    xcrun simctl shutdown "$sim" 2>/dev/null || true
    xcrun simctl delete "$sim" 2>/dev/null || true
}
trap cleanup EXIT
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b
build=(-project Slou.xcodeproj -scheme Slou -configuration Debug -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$tmp/build" -parallel-testing-enabled NO)
xcodebuild "${build[@]}" build-for-testing > "$out/build.log" 2>&1 || { tail -100 "$out/build.log"; exit 1; }

# Capture the normal app in the same offline state that the UI tests exercise.
xcrun simctl install "$sim" "$tmp/build/Build/Products/Debug-iphonesimulator/Slou.app"
xcrun simctl launch "$sim" app.slou.watch -server http://localhost:1
sleep 5
xcrun simctl io "$sim" screenshot "$out/home.png"
xcrun simctl io "$sim" recordVideo --codec=h264 --force "$out/entry.mp4" > "$out/record.log" 2>&1 &
rec=$!
for ((i=0; i<50; i++)); do
    if grep -qi 'Recording started' "$out/record.log"; then break; fi
    sleep 0.1
done
sleep 0.6
xcrun simctl openurl "$sim" slou://demo
sleep 1.4
xcrun simctl io "$sim" screenshot "$out/room.png"
kill -INT "$rec"
wait "$rec" || true
rec=""
xcrun simctl terminate "$sim" app.slou.watch
status=0
xcodebuild "${build[@]}" -resultBundlePath "$tmp/tests.xcresult" test-without-building > "$out/tests.log" 2>&1 || status=$?
if [[ -d "$tmp/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$tmp/tests.xcresult" > "$out/summary.json" || true
    xcrun xcresulttool export attachments --path "$tmp/tests.xcresult" --output-path "$tmp/attachments" >/dev/null || true
    python3 - "$tmp/attachments" "$out" <<'PY'
import json, pathlib, shutil, sys
src, out = map(pathlib.Path, sys.argv[1:])
manifest = src/'manifest.json'
if manifest.is_file():
    for test in json.loads(manifest.read_text()):
        for attachment in test.get('attachments', []):
            if 'Slou demo match' in attachment.get('suggestedHumanReadableName',''):
                image = src/attachment['exportedFileName']
                if image.is_file():
                    shutil.copyfile(image, out/'match.png')
PY
fi
if [[ "$status" != 0 ]]; then tail -100 "$out/tests.log"; exit "$status"; fi
cat "$out/summary.json"
