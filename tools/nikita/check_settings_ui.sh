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
pathlib.Path(sys.argv[2], 'expected-frames.txt').write_text('''These are production controls in an isolated test host, recorded in both light and dark appearances. The host calls the actual ClassicDesign startup appearance installer before its window is created. Each phase name ends in -dark or -light.
Appearance/privacy: every multiline title and description fits inside its opaque solid card. No overlaps or clipped text. Switches keep the native size and have solid thumbs. Dark appearance has a black backdrop; light appearance has a light grouped backdrop. Symbols and labels retain readable contrast. No background image, refraction, blur or glass highlight shows through the cards.
Voice: title/value/slider stay inside one solid surface; no squashed symbols or gray icon chips. The slider thumb remains opaque.
Dashboard: artwork and labels share the solid content hierarchy. Cards are opaque on the first frame, with no fade, late material swap or glass elasticity.
Scroll/return: content and its opaque surface move together, upward then downward, and settle without a detached label or stale background. Only native scroll animation runs.
Text entry: the plain preset dialog opens above the keyboard when it is shown; its focused field contains «Радио». Save closes the panel once and its handler still reads that text after dismissal. Both buttons and all text remain inside the opaque panel.
Video error: the production plain alert has an opaque panel, complete readable diagnostic footer and separate Copy error/Keep draft buttons. Longer content remains reachable by scrolling, with no horizontal clipping. Copy error runs once with the shown diagnostic after dismissal. The panel and its content cross-fade together once on opening and once on closing, without refraction, liquid highlights or background morphing.
Media actions: the production plain action panel and its content cross-fade together and settle; Save and Start countdown are legible, aligned and inside the safe area; dismissal uses Cancel or a dimmed-area tap. After a countdown starts, Save and Cancel remain and Start is absent. No overlapping timer/action labels. The presenting controls stay in place; the plain panel must not morph the source screen or introduce glass during its transition. The custom-surface checks do not prove every full-app system component is opaque. Gallery/audio integration still requires a real account and received media.
Search: a plain UITextField, magnifier and cancel button stay inside the solid host, with aligned editing controls and keyboard. The field is readable on opaque surfaces in light and dark. Focus, text entry and cancellation use public controls; no native search material or private field subviews are used.
Icon carousel: the installed icon is initially centered. Artwork moves horizontally and scales together inside its clipping shape; labels, page dots and the explicit Apply button stay aligned below. Background interpolates with scrolling; Paper uses a cream backdrop with dark text, Chrome a red backdrop. Each animation settles once without a loop, late image or text overlap. Scrolling alone never applies an icon.
The recording does not establish physical-device frame rate, heat, or finger-driven elasticity; those need a full app device check.
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
while time.monotonic() - start < 600:
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
        # The video preserves the whole transition. Capture the named still after
        # the first rendering pass rather than during the previous phase's frame.
        time.sleep(.5)
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
        phases = {'appearance', 'privacy', 'voice', 'text-entry', 'video-error', 'media-actions', 'media-actions-started', 'dashboard', 'scroll', 'return', 'search', 'icons-original', 'icons-clip', 'icons-paper', 'icons-pixel', 'icons-chrome', 'icons-stairs', 'icons-applied'}
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

