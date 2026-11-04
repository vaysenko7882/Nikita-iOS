#!/usr/bin/env bash
# Production live-feed and scroll anchoring driven by a real loopback HTTP
# archive, in an isolated iOS Simulator. No Telegram account is used.
set -euo pipefail
CODEGRAM_HISTORY_OUT="${1:-$RUNNER_TEMP/codegram-profile-history}"
mkdir -p "$CODEGRAM_HISTORY_OUT"
rm -f "$CODEGRAM_HISTORY_OUT/port.txt" "$CODEGRAM_HISTORY_OUT/result.json" "$CODEGRAM_HISTORY_OUT/timeline.json" "$CODEGRAM_HISTORY_OUT"/[0-9][0-9]-*.png
CODEGRAM_HISTORY_SIM=""
CODEGRAM_HISTORY_REC=""
CODEGRAM_HISTORY_SERVER=""
cleanup() {
    if [ -n "$CODEGRAM_HISTORY_REC" ]; then
        kill -INT "$CODEGRAM_HISTORY_REC" 2>/dev/null || true
        wait "$CODEGRAM_HISTORY_REC" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_HISTORY_SERVER" ]; then
        kill "$CODEGRAM_HISTORY_SERVER" 2>/dev/null || true
        wait "$CODEGRAM_HISTORY_SERVER" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_HISTORY_SIM" ]; then
        xcrun simctl shutdown "$CODEGRAM_HISTORY_SIM" 2>/dev/null || true
        xcrun simctl delete "$CODEGRAM_HISTORY_SIM" 2>/dev/null || true
    fi
}
trap cleanup EXIT
CODEGRAM_HISTORY_APP="$CODEGRAM_HISTORY_OUT/ProfileHistoryHarness.app"
mkdir -p "$CODEGRAM_HISTORY_APP"
python3 - "$CODEGRAM_HISTORY_APP" "$CODEGRAM_HISTORY_OUT" <<'PY'
import json, pathlib, plistlib, sys
app, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
plist = dict(CFBundleIdentifier='com.codegram.ProfileHistoryRegression', CFBundleExecutable='ProfileHistoryHarness', CFBundleName='History HTTP fixtures', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0', UIDeviceFamily=[1, 2], UILaunchScreen={}, NSAppTransportSecurity={'NSAllowsLocalNetworking': True, 'NSAllowsArbitraryLoads': True}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
(out / 'expected-frames.txt').write_text('''The running code is the production CodeGramProfileHistoryFeed, CodeGramProfileHistoryScrollAnchor and self-sizing CodeGramTextCell, with a loopback HTTP archive and a native UITableView reproducing the production manual navigation inset (120 pt, initial offset zero). Row descriptions vary in length to exercise real estimated-to-measured geometry.
01 -> 02: a story published over HTTP appears automatically in the first visible history row, with no Refresh button or manual feed refresh. Offset remains zero; no inset condition can disable polling.
03 -> 04 -> 05: an older visible record stays at the same screen Y after a story and an 80-event burst are inserted above it. Another newly published story reaches the head while the old gap is still being backfilled. Older pages remain loaded and the burst is fetched without a pagination gap. No unexpected scroll jump or duplicate row.
06: with the parent history reader stopped, the open selected event polls its fixed sequence/limit-one HTTP page. Its file becomes ready automatically; selected archive/event and immutable before/after payload stay unchanged. The saved-file state is visible. Returning to the history updates the same event without a duplicate.
07: cancelling an in-flight HTTP response while hidden does not apply it; reopening fetches the new story automatically.
08 -> 09: the host backgrounds the app by opening Settings, publishes another story, then returns. No background history requests; the foreground shows that event without a Refresh action.
10 -> 11: replacing the archive epoch discards the old feed cache and pagination state. While rendering is deferred, the old rows retain their original archive identity and a simulated row selection refuses the new archive. Once rendered, a new row has its matching identity. Records from two databases are never mixed.
No custom animation is added: native table updates preserve their reading position. The recording tests the live reader and UIKit anchoring, not Telegram's delivery of a real account's stories or device temperature.
''')
PY
printf '%s\n' 'Compiling production history feed and native fixture before HTTP startup'
if ! xcrun --sdk iphonesimulator swiftc -parse-as-library -warnings-as-errors \
    -target "$(uname -m)-apple-ios26.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    submodules/SettingsUI/Sources/CodeGramSettingsTheme.swift \
    submodules/SettingsUI/Sources/CodeGramSettingsCells.swift \
    submodules/SettingsUI/Sources/CodeGramProfileHistoryFeed.swift \
    tools/nikita/tests/ProfileHistoryUIHarness.swift -o "$CODEGRAM_HISTORY_APP/ProfileHistoryHarness" > "$CODEGRAM_HISTORY_OUT/swift-build.log" 2>&1; then
    cat "$CODEGRAM_HISTORY_OUT/swift-build.log" >&2
    exit 1
fi
printf '%s\n' 'Native history fixture compiled; starting loopback HTTP server'
xcrun simctl list runtimes --json > "$CODEGRAM_HISTORY_OUT/runtimes.json"
CODEGRAM_HISTORY_RUNTIME=$(python3 - "$CODEGRAM_HISTORY_OUT/runtimes.json" <<'PY'
import json, sys
models = {'iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro', 'iPhone 17'}
rows = [r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and r.get('platform') == 'iOS' and int(r['version'].split('.')[0]) >= 26 and any(d['name'] in models for d in r.get('supportedDeviceTypes', []))]
if not rows:
    raise SystemExit('Native history checks need an installed iOS 26+ Simulator')
print(max(rows, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)
CODEGRAM_HISTORY_DEVICE=$(python3 - "$CODEGRAM_HISTORY_OUT/runtimes.json" "$CODEGRAM_HISTORY_RUNTIME" <<'PY'
import json, sys
runtime = next(r for r in json.load(open(sys.argv[1]))['runtimes'] if r['identifier'] == sys.argv[2])
for name in ['iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro', 'iPhone 17']:
    found = next((r for r in runtime['supportedDeviceTypes'] if r['name'] == name), None)
    if found:
        print(found['identifier'])
        break
else:
    raise SystemExit('No supported history-fixture iPhone Simulator')
PY
)
python3 -u tools/nikita/profile_history_fixture.py --port-file "$CODEGRAM_HISTORY_OUT/port.txt" > "$CODEGRAM_HISTORY_OUT/http.log" 2>&1 &
CODEGRAM_HISTORY_SERVER=$!
CODEGRAM_HISTORY_DEADLINE=$((SECONDS + 30))
while [ "$SECONDS" -lt "$CODEGRAM_HISTORY_DEADLINE" ]; do
    if [ -s "$CODEGRAM_HISTORY_OUT/port.txt" ]; then break; fi
    if ! kill -0 "$CODEGRAM_HISTORY_SERVER" 2>/dev/null; then
        CODEGRAM_HISTORY_STATUS=0
        wait "$CODEGRAM_HISTORY_SERVER" || CODEGRAM_HISTORY_STATUS=$?
        printf 'Profile HTTP fixture exited before readiness (status %s)\n' "$CODEGRAM_HISTORY_STATUS" >&2
        cat "$CODEGRAM_HISTORY_OUT/http.log" >&2
        exit 1
    fi
    sleep 0.1
done
if [ ! -s "$CODEGRAM_HISTORY_OUT/port.txt" ]; then
    printf 'Profile HTTP fixture did not become ready within 30 seconds (pid %s)\n' "$CODEGRAM_HISTORY_SERVER" >&2
    ps -p "$CODEGRAM_HISTORY_SERVER" -o pid=,stat=,etime=,command= >&2 || true
    cat "$CODEGRAM_HISTORY_OUT/http.log" >&2
    exit 1
fi
cat "$CODEGRAM_HISTORY_OUT/http.log"
python3 - "$CODEGRAM_HISTORY_APP" "$CODEGRAM_HISTORY_OUT/port.txt" <<'PY'
import json, pathlib, sys, urllib.request
app, port_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
base = 'http://127.0.0.1:' + port_file.read_text().strip() + '/'
with urllib.request.urlopen(base + 'stats', timeout=5) as response:
    json.load(response)
(app / 'fixture.json').write_text(json.dumps({'url': base}))
print('Profile HTTP fixture readiness probe passed')
PY
codesign --force --sign - "$CODEGRAM_HISTORY_APP"
CODEGRAM_HISTORY_SIM=$(xcrun simctl create "CodeGram History ${GITHUB_RUN_ID:-local}" "$CODEGRAM_HISTORY_DEVICE" "$CODEGRAM_HISTORY_RUNTIME")
xcrun simctl boot "$CODEGRAM_HISTORY_SIM"
xcrun simctl bootstatus "$CODEGRAM_HISTORY_SIM" -b
xcrun simctl install "$CODEGRAM_HISTORY_SIM" "$CODEGRAM_HISTORY_APP"
CODEGRAM_HISTORY_DATA=$(xcrun simctl get_app_container "$CODEGRAM_HISTORY_SIM" com.codegram.ProfileHistoryRegression data)
xcrun simctl status_bar "$CODEGRAM_HISTORY_SIM" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl io "$CODEGRAM_HISTORY_SIM" recordVideo --codec=h264 --force "$CODEGRAM_HISTORY_OUT/profile-live.mp4" > "$CODEGRAM_HISTORY_OUT/recording.log" 2>&1 &
CODEGRAM_HISTORY_REC=$!
python3 - "$CODEGRAM_HISTORY_OUT/recording.log" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(100):
    if path.exists() and 'Recording started' in path.read_text():
        break
    time.sleep(.1)
else:
    raise SystemExit('History recording did not start')
PY
xcrun simctl launch --stdout="$CODEGRAM_HISTORY_OUT/console.log" --stderr="$CODEGRAM_HISTORY_OUT/stderr.log" "$CODEGRAM_HISTORY_SIM" com.codegram.ProfileHistoryRegression
python3 - "$CODEGRAM_HISTORY_SIM" "$CODEGRAM_HISTORY_DATA/Documents" "$CODEGRAM_HISTORY_OUT" <<'PY'
import json, pathlib, shutil, subprocess, sys, time, urllib.request
sim, documents, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
base = 'http://127.0.0.1:' + (output / 'port.txt').read_text().strip()
def request(path, method='GET'):
    with urllib.request.urlopen(urllib.request.Request(base + path, method=method), timeout=5) as result:
        return json.load(result)
seen, timeline = set(), []
start = time.monotonic()
while time.monotonic() - start < 600:
    phase_path = documents / 'phase.txt'
    phase = phase_path.read_text() if phase_path.exists() else ''
    if phase and phase not in seen:
        seen.add(phase)
        timeline.append({'phase': phase, 'seconds_after_launch': round(time.monotonic() - start, 3)})
        subprocess.run(['xcrun', 'simctl', 'io', sim, 'screenshot', str(output / (phase + '.png'))], check=True)
        (documents / ('captured-' + phase)).touch()
        if phase == '08-background-request':
            subprocess.run(['xcrun', 'simctl', 'launch', sim, 'com.apple.Preferences'], check=True)
            time.sleep(.7)
            before = request('/stats')['requests']
            latest = request('/publish', 'POST')['latest']
            time.sleep(1)
            after = request('/stats')['requests']
            subprocess.run(['xcrun', 'simctl', 'launch', sim, 'com.codegram.ProfileHistoryRegression'], check=True)
            # The app's HTTP deadline starts only after the host launch command
            # completes, not while a slow Simulator is still foregrounding it.
            foreground = documents / 'foreground-result.json'
            temporary = foreground.with_suffix('.tmp')
            temporary.write_text(json.dumps({'latest': latest, 'background_requests': after-before}))
            temporary.replace(foreground)
    result = documents / 'result.json'
    if result.exists():
        shutil.copyfile(result, output / 'result.json')
        (output / 'timeline.json').write_text(json.dumps(timeline, indent=2))
        report = json.loads(result.read_text())
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['failures'] or report['checks'] < 14 or report['manual_refreshes'] != 0:
            raise SystemExit('Native HTTP profile-history checks failed')
        break
    time.sleep(.1)
else:
    raise SystemExit('Native HTTP history fixture did not finish')
PY
