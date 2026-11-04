#!/usr/bin/env bash
# An isolated UIKit test host uses the production controls, without an account or
# modifications to an existing simulator. It is not a selective Telegram build.
set -euo pipefail
CODEGRAM_UI_OUT="${1:-$RUNNER_TEMP/codegram-ui}"
mkdir -p "$CODEGRAM_UI_OUT"
CODEGRAM_UI_SIM=""
CODEGRAM_UI_REC=""
CODEGRAM_UI_DATA=""
cleanup() {
    if [ -n "$CODEGRAM_UI_REC" ]; then
        kill -INT "$CODEGRAM_UI_REC" 2>/dev/null || true
        wait "$CODEGRAM_UI_REC" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_UI_SIM" ]; then
        python3 - "$CODEGRAM_UI_OUT" "$CODEGRAM_UI_DATA" "$CODEGRAM_UI_SIM" <<'PY'
import os, pathlib, shutil, subprocess, sys, time
output, data, sim = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if data:
    documents = pathlib.Path(data) / 'Documents'
    for name in ('phase.txt', 'runtime-progress.json', 'uncaught-exception.txt', 'result.json'):
        source = documents / name
        if source.is_file():
            shutil.copyfile(source, output / name)
home = pathlib.Path(os.environ['HOME'])
roots = [home / 'Library/Logs/DiagnosticReports', home / 'Library/Developer/CoreSimulator/Devices' / sim / 'data/Library/Logs/CrashReporter']
crashes = output / 'crash-reports'
for root in roots:
    if root.is_dir():
        for source in root.rglob('*'):
            try:
                if not source.is_file() or source.suffix not in ('.ips', '.crash') or source.stat().st_mtime < time.time() - 3600:
                    continue
                text = source.read_text(errors='replace')
                if 'SettingsHarness' not in text and 'com.codegram.UIRegression' not in text:
                    continue
                crashes.mkdir(exist_ok=True)
                shutil.copyfile(source, crashes / source.name)
            except (FileNotFoundError, PermissionError):
                pass
if not (output / 'result.json').is_file():
    with (output / 'simulator-system.log').open('w') as log:
        try:
            subprocess.run(['xcrun', 'simctl', 'spawn', sim, 'log', 'show', '--last', '15m', '--style', 'compact', '--predicate', 'process == "SettingsHarness" OR eventMessage CONTAINS "com.codegram.UIRegression"'], stdout=log, stderr=subprocess.STDOUT, timeout=20, check=False)
        except subprocess.TimeoutExpired:
            log.write('\nUnified-log collection stopped after 20 seconds.\n')
PY
        xcrun simctl shutdown "$CODEGRAM_UI_SIM" 2>/dev/null || true
        xcrun simctl delete "$CODEGRAM_UI_SIM" 2>/dev/null || true
    fi
}
trap cleanup EXIT
xcrun simctl list runtimes --json > "$CODEGRAM_UI_OUT/runtimes.json"
xcrun simctl list devicetypes --json > "$CODEGRAM_UI_OUT/devicetypes.json"
CODEGRAM_UI_RUNTIME=$(python3 - "$CODEGRAM_UI_OUT/runtimes.json" <<'PY'
import json, sys
standard = {'iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro'}
rows = [r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and r.get('platform') == 'iOS' and int(r['version'].split('.')[0]) >= 26 and any(d['name'] in standard for d in r.get('supportedDeviceTypes', []))]
if not rows:
    raise SystemExit('Native UI checks need an installed iOS 26+ Simulator runtime')
print(max(rows, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)
CODEGRAM_UI_DEVICE=$(python3 - "$CODEGRAM_UI_OUT/runtimes.json" "$CODEGRAM_UI_RUNTIME" <<'PY'
import json, sys
runtime = next(r for r in json.load(open(sys.argv[1]))['runtimes'] if r['identifier'] == sys.argv[2])
rows = runtime['supportedDeviceTypes']
for name in ['iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro']:
    found = next((r for r in rows if r['name'] == name), None)
    if found:
        print(found['identifier']); break
else:
    raise SystemExit('No supported iPhone Simulator device type')
PY
)
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
pathlib.Path(sys.argv[2], 'expected-frames.txt').write_text('''These are actual production controls in an isolated UIKit host, recorded in light and dark appearances. The startup installer runs before the first window. ClassicDesign and GlassEffects remain false: modern geometry stays enabled while public system-bar appearances and item backgrounds have no glass effect. Native isTranslucent is allowed to keep modern bar geometry.
Appearance/privacy/voice: rows touch within each section, with one connected opaque group, 22pt outer corners, square inner corners and a physical-pixel inset separator. There is no individual-card gap. Rows are at least 52pt and expand for multiline text through the largest accessibility size. Native switches remain full size, white slider thumbs stay opaque, and all labels fit with readable contrast in both appearances.
Dashboard: three full-width connected groups contain Ghost/Archive, the four feature destinations, then Storage/Additional. Rows touch within each group, with 24pt outer corners; only group boundaries have 20pt spacing. Artwork and labels move together with the opaque content on initial display, scroll and return, with no delayed material swap.
Text entry: the production preset dialog opens above the keyboard with focused text «Радио». Save runs once after closing and retains the text. The opaque panel has 32pt corners, capsule buttons, no glass and a maximum width of 340pt.
Video error: the production opaque alert has complete readable diagnostics and separate Copy error/Keep draft buttons. Content remains reachable by scrolling. Copy runs once after dismissal. Its opening and closing transition preserves panel geometry with no refraction.
Media actions: the production opaque action sheet has 32pt panel corners, capsule buttons and maximum width 520pt. Save and Start countdown remain legible and safe; after starting, Save/Cancel remain and Start is absent. Labels fit without overlap. Custom surfaces do not prove all authenticated app components are opaque.
Search: a native UITextField, magnifier and cancel button stay aligned inside the opaque search host. Focus, typing and cancel use public controls and preserve readable contrast.
Icon carousel: the installed icon opens centered in the real viewport. 176pt artwork moves at 210pt page spacing. The explicit Apply capsule stays 18pt above the bottom safe area, while the hero scrolls on short/accessibility screens. Paper uses cream with dark text; other backdrops and interpolated labels retain contrast. Scrolling alone never applies an icon.
All nine icon choices have an early transition/burst phase and a separate resting phase: Original pulse, Clip paths, Paper folds, Echo rings, Rift split, Slice lines, Pixel grid, Chrome sweep and Stairs. The raw video records each complete transition; named burst stills are requested immediately. Each one-shot effect has at most 35 layers, completes within 1.21 seconds, and removes all layers at 1.3 seconds. Hiding effects or removing the view clears layers. No animation loops continue after settling. An installed icon disables Apply with readable text.
These recordings do not establish physical-device frame rate, heat, finger-driven elasticity or authenticated integration.
''')
PY
CODEGRAM_UI_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CODEGRAM_UI_OBJC_OBJECTS=()
for CODEGRAM_UI_OBJC_SOURCE in \
    submodules/ObjCRuntimeUtils/Source/ObjCRuntimeUtils/RuntimeUtils.m \
    submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/NSBag.m \
    submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/NSWeakReference.m \
    submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UINavigationItem+Proxy.m; do
    CODEGRAM_UI_OBJECT="$CODEGRAM_UI_OUT/$(basename "$CODEGRAM_UI_OBJC_SOURCE" .m).o"
    xcrun --sdk iphonesimulator clang -c -fobjc-arc -fblocks -fmodules \
        -target "$(uname -m)-apple-ios26.0-simulator" -isysroot "$CODEGRAM_UI_SDK" \
        -I submodules/ObjCRuntimeUtils/Source -I submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils \
        "$CODEGRAM_UI_OBJC_SOURCE" -o "$CODEGRAM_UI_OBJECT"
    CODEGRAM_UI_OBJC_OBJECTS+=("$CODEGRAM_UI_OBJECT")
done
xcrun --sdk iphonesimulator swiftc -parse-as-library -warnings-as-errors \
    -target "$(uname -m)-apple-ios26.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    submodules/Display/Source/ClassicDesign.swift \
    submodules/SettingsUI/Sources/CodeGramSettingsTheme.swift \
    submodules/SettingsUI/Sources/CodeGramSettingsCells.swift \
    submodules/SettingsUI/Sources/CodeGramIconPickerView.swift \
    submodules/SettingsUI/Sources/CodeGramDashboardComponents.swift \
    submodules/Display/Source/CodeGramMediaActions.swift \
    tools/nikita/tests/SettingsUIHarness.swift "${CODEGRAM_UI_OBJC_OBJECTS[@]}" -framework QuartzCore -o "$CODEGRAM_UI_APP/SettingsHarness"
cp Telegram/Telegram-iOS/CodeGramIconPreviews/*.png "$CODEGRAM_UI_APP/"
codesign --force --sign - "$CODEGRAM_UI_APP"
CODEGRAM_UI_SIM=$(xcrun simctl create "CodeGram UI ${GITHUB_RUN_ID:-local}" "$CODEGRAM_UI_DEVICE" "$CODEGRAM_UI_RUNTIME")
xcrun simctl boot "$CODEGRAM_UI_SIM"
xcrun simctl bootstatus "$CODEGRAM_UI_SIM" -b
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
CODEGRAM_UI_LAUNCH=$(xcrun simctl launch --stdout="$CODEGRAM_UI_OUT/console.log" --stderr="$CODEGRAM_UI_OUT/stderr.log" "$CODEGRAM_UI_SIM" com.codegram.UIRegression)
printf '%s\n' "$CODEGRAM_UI_LAUNCH"
python3 - "$CODEGRAM_UI_SIM" "$CODEGRAM_UI_DATA/Documents" "$CODEGRAM_UI_OUT" "$CODEGRAM_UI_LAUNCH" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys, time
sim, documents, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
match = re.search(r':\s*(\d+)\s*$', sys.argv[4])
if not match:
    raise SystemExit('Simulator launch did not return the native harness PID: ' + sys.argv[4])
pid = int(match.group(1))
seen, timeline = set(), []
start = time.monotonic()
while time.monotonic() - start < 900:
    for name in ('runtime-progress.json', 'uncaught-exception.txt'):
        source = documents / name
        if source.is_file():
            shutil.copyfile(source, output / name)
    exception = documents / 'uncaught-exception.txt'
    if exception.is_file():
        raise SystemExit('Native settings harness exception:\n' + exception.read_text())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        progress = documents / 'runtime-progress.json'
        detail = progress.read_text() if progress.is_file() else 'No runtime breadcrumb was written.'
        raise SystemExit('Native settings harness exited before result.json. Last progress:\n' + detail)
    phase_path = documents / 'phase.txt'
    phase = phase_path.read_text() if phase_path.exists() else ''
    if phase and phase not in seen:
        seen.add(phase)
        detected = round(time.monotonic() - start, 3)
        # The raw video preserves each complete transition. Request early burst
        # frames promptly while the real one-shot layers are still active.
        time.sleep(.05 if '-burst-' in phase else .5)
        subprocess.run(['xcrun', 'simctl', 'io', sim, 'screenshot', str(output / (phase + '.png'))], check=True)
        timeline.append({'phase': phase, 'phase_seen_after_launch': detected, 'seconds_after_launch': round(time.monotonic() - start, 3)})
        (documents / ('captured-' + phase)).touch()
    result = documents / 'result.json'
    if result.exists():
        shutil.copyfile(result, output / 'result.json')
        (output / 'timeline.json').write_text(json.dumps(timeline, indent=2))
        report = json.loads(result.read_text())
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['failures'] or report['checks'] < 500: raise SystemExit('Native settings UI regression checks failed')
        phases = {'appearance', 'privacy', 'voice', 'text-entry', 'video-error', 'media-actions', 'media-actions-started', 'dashboard', 'scroll', 'return', 'search', 'icons-original-burst', 'icons-original', 'icons-clip-burst', 'icons-clip', 'icons-paper-burst', 'icons-paper', 'icons-echo-burst', 'icons-echo', 'icons-rift-burst', 'icons-rift', 'icons-slice-burst', 'icons-slice', 'icons-pixel-burst', 'icons-pixel', 'icons-chrome-burst', 'icons-chrome', 'icons-stairs-burst', 'icons-stairs', 'icons-effects-stopped', 'icons-applied'}
        required = {phase + '-' + style for phase in phases for style in ('dark', 'light')}
        missing = sorted(required - seen)
        if missing or report.get('recorded_styles') != ['dark', 'light']:
            raise SystemExit('Missing light/dark recorded phases: ' + ', '.join(missing))
        if any(not (output / (phase + '.png')).is_file() for phase in required):
            raise SystemExit('A required phase screenshot was not saved')
        break
    time.sleep(.25)
else: raise SystemExit('Native settings harness did not finish')
PY

