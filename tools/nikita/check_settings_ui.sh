#!/usr/bin/env bash
# An isolated UIKit test host uses the production controls, without an account or
# modifications to an existing simulator. It is not a selective Telegram build.
set -euo pipefail
CODEGRAM_UI_OUT="${1:-$RUNNER_TEMP/codegram-ui}"
mkdir -p "$CODEGRAM_UI_OUT"
CODEGRAM_UI_SIM=""
CODEGRAM_UI_REC=""
cleanup() {
    if [ -n "$CODEGRAM_UI_REC" ]; then
        kill -INT "$CODEGRAM_UI_REC" 2>/dev/null || true
        wait "$CODEGRAM_UI_REC" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_UI_SIM" ]; then
        xcrun simctl shutdown "$CODEGRAM_UI_SIM" 2>/dev/null || true
        xcrun simctl delete "$CODEGRAM_UI_SIM" 2>/dev/null || true
    fi
}
trap cleanup EXIT
xcrun simctl list runtimes --json > "$CODEGRAM_UI_OUT/runtimes.json"
xcrun simctl list devicetypes --json > "$CODEGRAM_UI_OUT/devicetypes.json"
CODEGRAM_UI_RUNTIME=$(python3 - "$CODEGRAM_UI_OUT/runtimes.json" <<'PY'
import json, sys
rows = [r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and 'iOS-' in r['identifier'] and int(r['version'].split('.')[0]) >= 26]
if not rows:
    raise SystemExit('Native UI checks need an installed iOS 26+ Simulator runtime')
print(max(rows, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)
CODEGRAM_UI_DEVICE=$(python3 - "$CODEGRAM_UI_OUT/devicetypes.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))['devicetypes']
for name in ['iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro']:
    found = next((r for r in rows if r['name'] == name), None)
    if found:
        print(found['identifier']); break
else:
    raise SystemExit('No supported iPhone Simulator device type')
PY
)
CODEGRAM_UI_SIM=$(xcrun simctl create "CodeGram UI ${GITHUB_RUN_ID:-local}" "$CODEGRAM_UI_DEVICE" "$CODEGRAM_UI_RUNTIME")
xcrun simctl boot "$CODEGRAM_UI_SIM"
xcrun simctl bootstatus "$CODEGRAM_UI_SIM" -b
CODEGRAM_UI_APP="$CODEGRAM_UI_OUT/SettingsHarness.app"
mkdir -p "$CODEGRAM_UI_APP"
python3 - "$CODEGRAM_UI_APP" "$CODEGRAM_UI_OUT" <<'PY'
import json, pathlib, plistlib, re, sys
app = pathlib.Path(sys.argv[1])
plist = dict(CFBundleIdentifier='com.codegram.UIRegression', CFBundleExecutable='SettingsHarness', CFBundleName='CodeGram UI fixtures', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0', UIDeviceFamily=[1, 2], UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
names = {'key', 'link', 'internaldrive', 'server.rack', 'capsule', 'rectangle.3.group'}
for path in pathlib.Path('submodules/SettingsUI/Sources').glob('CodeGram*.swift'):
    text = path.read_text()
    names.update(re.findall(r'(?:icon|symbol|systemName):\s*"([a-z][a-z0-9.]*)"', text))
    names.update(re.findall(r'return "([a-z][a-z0-9.]*)"', text))
names.discard('codegram.ghost')
(app / 'icons.json').write_text(json.dumps(sorted(names)))
pathlib.Path(sys.argv[2], 'expected-frames.txt').write_text('''These are native controls from production sources in an isolated test host.
Appearance/privacy: every multiline title and description fits inside its own glass card. No overlaps or clipped text. Switches keep the native size. Black backdrop, distinct monochrome symbols.
Voice: title/value/slider stay inside one material; no squashed symbols or gray icon chips.
Dashboard: artwork and labels share the material content hierarchy. Glass appears on the first displayed cards without a custom fade or a late flat-to-glass swap.
Scroll/return: content and its material move together, upward then downward, and settle without a detached label or stale material. Only native scroll animation runs.
Search: the real UISearchBar stays inside the material, with aligned icons, editing controls and keyboard. No effects injected into private field subviews.
The recording does not establish physical-device frame rate, heat, or finger-driven elasticity; those need a full app device check.
''')
PY
xcrun --sdk iphonesimulator swiftc -parse-as-library -warnings-as-errors \
    -target "$(uname -m)-apple-ios26.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    submodules/SettingsUI/Sources/CodeGramSettingsTheme.swift \
    submodules/SettingsUI/Sources/CodeGramSettingsCells.swift \
    submodules/SettingsUI/Sources/CodeGramDashboardComponents.swift \
    tools/nikita/tests/SettingsUIHarness.swift -o "$CODEGRAM_UI_APP/SettingsHarness"
codesign --force --sign - "$CODEGRAM_UI_APP"
xcrun simctl install "$CODEGRAM_UI_SIM" "$CODEGRAM_UI_APP"
CODEGRAM_UI_DATA=$(xcrun simctl get_app_container "$CODEGRAM_UI_SIM" com.codegram.UIRegression data)
xcrun simctl status_bar "$CODEGRAM_UI_SIM" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl io "$CODEGRAM_UI_SIM" recordVideo --codec=h264 --force "$CODEGRAM_UI_OUT/native-controls.mp4" > "$CODEGRAM_UI_OUT/recording.log" 2>&1 &
CODEGRAM_UI_REC=$!
python3 - "$CODEGRAM_UI_OUT/recording.log" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(100):
    if path.exists() and 'Recording started' in path.read_text(): break
    time.sleep(.1)
else: raise SystemExit('Simulator recording did not start')
PY
xcrun simctl launch --stdout="$CODEGRAM_UI_OUT/console.log" --stderr="$CODEGRAM_UI_OUT/stderr.log" "$CODEGRAM_UI_SIM" com.codegram.UIRegression
python3 - "$CODEGRAM_UI_SIM" "$CODEGRAM_UI_DATA/Documents" "$CODEGRAM_UI_OUT" <<'PY'
import json, pathlib, shutil, subprocess, sys, time
sim, documents, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
seen, timeline = set(), []
start = time.monotonic()
while time.monotonic() - start < 180:
    phase_path = documents / 'phase.txt'
    phase = phase_path.read_text() if phase_path.exists() else ''
    if phase and phase not in seen:
        seen.add(phase)
        timeline.append({'phase': phase, 'seconds_after_launch': round(time.monotonic() - start, 3)})
        subprocess.run(['xcrun', 'simctl', 'io', sim, 'screenshot', str(output / (phase + '.png'))], check=True)
    result = documents / 'result.json'
    if result.exists():
        shutil.copyfile(result, output / 'result.json')
        (output / 'timeline.json').write_text(json.dumps(timeline, indent=2))
        report = json.loads(result.read_text())
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['failures'] or report['checks'] < 500: raise SystemExit('Native settings UI regression checks failed')
        break
    time.sleep(.25)
else: raise SystemExit('Native settings harness did not finish')
PY
