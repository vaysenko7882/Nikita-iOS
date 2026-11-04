#!/usr/bin/env bash
# Compile the production sender-only video status view in an isolated UIKit host.
# Record native keyboard/composer interaction without an account or download.
set -euo pipefail
CODEGRAM_VIDEO_UI_OUT="${1:-$RUNNER_TEMP/codegram-video-ui}"
mkdir -p "$CODEGRAM_VIDEO_UI_OUT"
CODEGRAM_VIDEO_UI_SIM=""
CODEGRAM_VIDEO_UI_REC=""
CODEGRAM_VIDEO_UI_DATA=""
cleanup() {
    if [ -n "$CODEGRAM_VIDEO_UI_REC" ]; then
        kill -INT "$CODEGRAM_VIDEO_UI_REC" 2>/dev/null || true
        wait "$CODEGRAM_VIDEO_UI_REC" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_VIDEO_UI_SIM" ]; then
        python3 - "$CODEGRAM_VIDEO_UI_OUT" "$CODEGRAM_VIDEO_UI_DATA" "$CODEGRAM_VIDEO_UI_SIM" <<'PY'
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
                if 'VideoStatusHarness' not in text and 'com.codegram.VideoStatusRegression' not in text:
                    continue
                crashes.mkdir(exist_ok=True)
                shutil.copyfile(source, crashes / source.name)
            except (FileNotFoundError, PermissionError):
                pass
if not (output / 'result.json').is_file():
    with (output / 'simulator-system.log').open('w') as log:
        try:
            subprocess.run(['xcrun', 'simctl', 'spawn', sim, 'log', 'show', '--last', '15m', '--style', 'compact', '--predicate', 'process == "VideoStatusHarness" OR eventMessage CONTAINS "com.codegram.VideoStatusRegression"'], stdout=log, stderr=subprocess.STDOUT, timeout=20, check=False)
        except subprocess.TimeoutExpired:
            log.write('\nUnified-log collection stopped after 20 seconds.\n')
PY
        xcrun simctl shutdown "$CODEGRAM_VIDEO_UI_SIM" 2>/dev/null || true
        xcrun simctl delete "$CODEGRAM_VIDEO_UI_SIM" 2>/dev/null || true
    fi
}
trap cleanup EXIT
xcrun simctl list runtimes --json > "$CODEGRAM_VIDEO_UI_OUT/runtimes.json"
xcrun simctl list devicetypes --json > "$CODEGRAM_VIDEO_UI_OUT/devicetypes.json"
CODEGRAM_VIDEO_UI_RUNTIME=$(python3 - "$CODEGRAM_VIDEO_UI_OUT/runtimes.json" <<'PY'
import json, sys
standard = {'iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro'}
rows = [r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and r.get('platform') == 'iOS' and int(r['version'].split('.')[0]) >= 26 and any(d['name'] in standard for d in r.get('supportedDeviceTypes', []))]
if not rows:
    raise SystemExit('Native UI checks need an installed iOS 26+ Simulator runtime')
print(max(rows, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)
CODEGRAM_VIDEO_UI_DEVICE=$(python3 - "$CODEGRAM_VIDEO_UI_OUT/runtimes.json" "$CODEGRAM_VIDEO_UI_RUNTIME" <<'PY'
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
CODEGRAM_VIDEO_UI_APP="$CODEGRAM_VIDEO_UI_OUT/VideoStatusHarness.app"
mkdir -p "$CODEGRAM_VIDEO_UI_APP"
python3 - "$CODEGRAM_VIDEO_UI_APP" "$CODEGRAM_VIDEO_UI_OUT" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
plist = dict(CFBundleIdentifier='com.codegram.VideoStatusRegression', CFBundleExecutable='VideoStatusHarness', CFBundleName='CodeGram video status fixtures', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0', UIDeviceFamily=[1, 2], UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'], UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
pathlib.Path(sys.argv[2], 'expected-frames.txt').write_text('''Actual production CodeGramSocialVideoStatusView.swift is compiled in this isolated UIKit host. It is sender-only and never presented as a modal. Each phase is recorded in dark and light.
Preparing: the bounded opaque18pt banner reports two queued videos, shows Cancel, and leaves the native composer focused. Text is inserted through UITextInput while the banner is visible; the composer and ordinary chat action receive hit tests.
Cancelled: Retry, Copy link and Close are available. Retry invokes the same production primary callback; the composer remains editable.
Enqueueing: the banner reports the Telegram queue phase and hides Cancel, while typing remains available.
Failed: Retry, Copy error and Close are legible and receive taps. Action callbacks run; the composer is still usable.
Queue full: the actual isNotice presentation is visible with no queued entries. It shows Close only, hides Retry/Copy, stops its spinner, and preserves the draft and native typing. Queue-notice-dismissed proves Close removes that notice without changing the draft or stealing composer input.
Landscape: the real window scene rotates, relays out its actual production banner and native keyboard/composer, and remains editable without a modal blocker.
Accessibility: the production view uses the largest accessibility category. Action titles fit, buttons retain44pt targets, error actions wrap below preview labels on narrow/AX layouts, and labels/buttons stay inside the opaque banner without overlapping.
Dismissed: Close removes the sender-only record while typing continues. The production spinner runs only for an active onscreen preparing/enqueueing record, stops on resign-active, and stops when detached. No glass material is used.
The raw video preserves transitions and keyboard movement. This fixture does not prove authenticated download success, Telegram upload/delivery, a recipient timeline, physical-device heat or frame rate.
''')
PY
CODEGRAM_VIDEO_UI_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -parse-as-library -warnings-as-errors \
    -target "$(uname -m)-apple-ios26.0-simulator" -sdk "$CODEGRAM_VIDEO_UI_SDK" \
    submodules/TelegramUI/Sources/CodeGramSocialVideoStatusView.swift \
    tools/nikita/tests/VideoStatusUIHarness.swift -framework UIKit -o "$CODEGRAM_VIDEO_UI_APP/VideoStatusHarness"
codesign --force --sign - "$CODEGRAM_VIDEO_UI_APP"
CODEGRAM_VIDEO_UI_SIM=$(xcrun simctl create "CodeGram video UI ${GITHUB_RUN_ID:-local}" "$CODEGRAM_VIDEO_UI_DEVICE" "$CODEGRAM_VIDEO_UI_RUNTIME")
xcrun simctl boot "$CODEGRAM_VIDEO_UI_SIM"
xcrun simctl bootstatus "$CODEGRAM_VIDEO_UI_SIM" -b
xcrun simctl install "$CODEGRAM_VIDEO_UI_SIM" "$CODEGRAM_VIDEO_UI_APP"
CODEGRAM_VIDEO_UI_DATA=$(xcrun simctl get_app_container "$CODEGRAM_VIDEO_UI_SIM" com.codegram.VideoStatusRegression data)
xcrun simctl status_bar "$CODEGRAM_VIDEO_UI_SIM" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl io "$CODEGRAM_VIDEO_UI_SIM" recordVideo --codec=h264 --force "$CODEGRAM_VIDEO_UI_OUT/native-controls.mp4" > "$CODEGRAM_VIDEO_UI_OUT/recording.log" 2>&1 &
CODEGRAM_VIDEO_UI_REC=$!
python3 - "$CODEGRAM_VIDEO_UI_OUT/recording.log" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(100):
    if path.exists() and 'Recording started' in path.read_text(): break
    time.sleep(.1)
else: raise SystemExit('Simulator recording did not start')
PY
CODEGRAM_VIDEO_UI_LAUNCH=$(xcrun simctl launch --stdout="$CODEGRAM_VIDEO_UI_OUT/console.log" --stderr="$CODEGRAM_VIDEO_UI_OUT/stderr.log" "$CODEGRAM_VIDEO_UI_SIM" com.codegram.VideoStatusRegression)
printf '%s\n' "$CODEGRAM_VIDEO_UI_LAUNCH"
python3 - "$CODEGRAM_VIDEO_UI_SIM" "$CODEGRAM_VIDEO_UI_DATA/Documents" "$CODEGRAM_VIDEO_UI_OUT" "$CODEGRAM_VIDEO_UI_LAUNCH" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys, time
sim, documents, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
match = re.search(r':\s*(\d+)\s*$', sys.argv[4])
if not match:
    raise SystemExit('Simulator launch did not return the native harness PID: ' + sys.argv[4])
pid = int(match.group(1))
seen, timeline = set(), []
start = time.monotonic()
while time.monotonic() - start < 450:
    for name in ('runtime-progress.json', 'uncaught-exception.txt'):
        source = documents / name
        if source.is_file():
            shutil.copyfile(source, output / name)
    exception = documents / 'uncaught-exception.txt'
    if exception.is_file():
        raise SystemExit('Native video status harness exception:\n' + exception.read_text())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        progress = documents / 'runtime-progress.json'
        detail = progress.read_text() if progress.is_file() else 'No runtime breadcrumb was written.'
        raise SystemExit('Native video status harness exited before result.json. Last progress:\n' + detail)
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
        if report['failures'] or report['checks'] < 500: raise SystemExit('Native video status UI regression checks failed')
        phases = {'preparing', 'cancelled', 'enqueueing', 'failed', 'queue-full', 'queue-notice-dismissed', 'landscape', 'accessibility', 'dismissed'}
        required = {phase + '-' + style for phase in phases for style in ('dark', 'light')}
        missing = sorted(required - seen)
        if missing or report.get('recorded_styles') != ['dark', 'light']:
            raise SystemExit('Missing light/dark recorded phases: ' + ', '.join(missing))
        if any(not (output / (phase + '.png')).is_file() for phase in required):
            raise SystemExit('A required phase screenshot was not saved')
        break
    time.sleep(.25)
else: raise SystemExit('Native video status harness did not finish')
PY

