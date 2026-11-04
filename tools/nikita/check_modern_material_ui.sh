#!/usr/bin/env bash
# An isolated UIKit fixture compiles the actual production material/geometry
# classes. It is not a selective Telegram-module or full application build.
set -euo pipefail
CODEGRAM_MATERIAL_OUT="${1:-$RUNNER_TEMP/codegram-modern-material}"
CODEGRAM_MATERIAL_APP="$CODEGRAM_MATERIAL_OUT/ModernMaterialHarness.app"
CODEGRAM_MATERIAL_MODULES="$CODEGRAM_MATERIAL_OUT/modules"
CODEGRAM_MATERIAL_STUBS="tools/nikita/tests/material-fixture-stubs"
CODEGRAM_MATERIAL_SIM=""
CODEGRAM_MATERIAL_REC=""
CODEGRAM_MATERIAL_DATA=""
mkdir -p "$CODEGRAM_MATERIAL_APP/Frameworks" "$CODEGRAM_MATERIAL_MODULES"
cleanup() {
    if [ -n "$CODEGRAM_MATERIAL_REC" ]; then
        kill -INT "$CODEGRAM_MATERIAL_REC" 2>/dev/null || true
        wait "$CODEGRAM_MATERIAL_REC" 2>/dev/null || true
    fi
    if [ -n "$CODEGRAM_MATERIAL_DATA" ] && [ -f "$CODEGRAM_MATERIAL_DATA/Documents/result.json" ]; then
        cp "$CODEGRAM_MATERIAL_DATA/Documents/result.json" "$CODEGRAM_MATERIAL_OUT/result.json"
    fi
    if [ -n "$CODEGRAM_MATERIAL_SIM" ]; then
        xcrun simctl shutdown "$CODEGRAM_MATERIAL_SIM" 2>/dev/null || true
        xcrun simctl delete "$CODEGRAM_MATERIAL_SIM" 2>/dev/null || true
    fi
}
trap cleanup EXIT
python3 - "$CODEGRAM_MATERIAL_OUT" "$CODEGRAM_MATERIAL_APP" <<'PY'
import hashlib, json, pathlib, plistlib, re, sys
output, app = map(pathlib.Path, sys.argv[1:])
source = pathlib.Path('submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift')
text = source.read_text()
marker = '\npublic final class GlassBackgroundComponent: Component {'
assert text.count(marker) == 1, 'Production source extraction boundary changed'
prefix = text[:text.index(marker)]
(output / 'GlassBackgroundView.production.swift').write_text(prefix)
geometry = text[text.index('    public struct CornerRadii: Equatable {'):text.index('    public struct Params: Equatable {')]
assignments = '\n'.join(line.strip() for line in prefix.splitlines() if re.search(r'transition\.set(Frame|Bounds|Position|CornerRadius|ShapeLayerPath)|nativeView\.frame =|classicClippingContext\?\.update|nativeViewClippingContext\.update', line))
expected = json.loads(pathlib.Path('tools/nikita/tests/material-fixture-stubs/baseline-geometry.json').read_text())
actual = dict(shape_clipping_sha256=hashlib.sha256(geometry.encode()).hexdigest(), layout_assignments_sha256=hashlib.sha256(assignments.encode()).hexdigest())
for key, value in actual.items():
    assert expected[key] == value, 'Modern geometry differs from baseline ' + expected['baseline_commit'] + ': ' + key
metadata = dict(production_path=str(source), production_source_sha256=hashlib.sha256(text.encode()).hexdigest(), compiled_prefix_sha256=hashlib.sha256(prefix.encode()).hexdigest(), compiled_lines=len(prefix.splitlines()), boundary=marker.strip(), baseline_geometry=expected, rendering='Actual production view, shape, clipping, material and update implementations', stand_ins='Immediate transition property setters, Display helpers, import-only modules, and trapping inactive renderer signatures')
(output / 'production-source.json').write_text(json.dumps(metadata, indent=2) + '\n')
plist = dict(CFBundleIdentifier='com.codegram.ModernMaterialFixture', CFBundleExecutable='ModernMaterialHarness', CFBundleName='Modern material geometry', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0', UIDeviceFamily=[1, 2], UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
(output / 'expected-frames.txt').write_text('''Actual production GlassBackgroundView fixtures, dark and light:
circle: x=24 y=160 width=56 height=56 radius=28
pill: x=110 y=163 width=180 height=50 radius=25
panel: x=24 y=250 width=300 height=96 radius=30
asymmetric panel: x=24 y=380 width=300 height=96 top radii=30 bottom radii=12
navigation group: x=24 y=520 width=300 height=54 radius=27 spacing=7
The material uses an opaque fill without UIVisualEffectView/backdrop filters.
Theme updates preserve outer frames and content bounds.
These isolated fixtures do not replace a complete Telegram build or device heat measurements.
''')
PY
CODEGRAM_MATERIAL_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CODEGRAM_MATERIAL_TARGET="$(uname -m)-apple-ios26.0-simulator"
xcrun --sdk iphonesimulator swiftc -emit-library -emit-module -module-name Display \
    -target "$CODEGRAM_MATERIAL_TARGET" -sdk "$CODEGRAM_MATERIAL_SDK" \
    -emit-module-path "$CODEGRAM_MATERIAL_MODULES/Display.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libDisplay.dylib \
    submodules/Display/Source/ClassicDesign.swift "$CODEGRAM_MATERIAL_STUBS/Display.swift" \
    -o "$CODEGRAM_MATERIAL_APP/Frameworks/libDisplay.dylib"
for CODEGRAM_MATERIAL_MODULE in ComponentFlow UIKitRuntimeUtils; do
    xcrun --sdk iphonesimulator swiftc -emit-library -emit-module -module-name "$CODEGRAM_MATERIAL_MODULE" \
        -target "$CODEGRAM_MATERIAL_TARGET" -sdk "$CODEGRAM_MATERIAL_SDK" \
        -emit-module-path "$CODEGRAM_MATERIAL_MODULES/$CODEGRAM_MATERIAL_MODULE.swiftmodule" \
        -Xlinker -install_name -Xlinker "@rpath/lib$CODEGRAM_MATERIAL_MODULE.dylib" \
        "$CODEGRAM_MATERIAL_STUBS/$CODEGRAM_MATERIAL_MODULE.swift" \
        -o "$CODEGRAM_MATERIAL_APP/Frameworks/lib$CODEGRAM_MATERIAL_MODULE.dylib"
done
for CODEGRAM_MATERIAL_MODULE in ComponentDisplayAdapters AppBundle; do
    xcrun --sdk iphonesimulator swiftc -emit-module -module-name "$CODEGRAM_MATERIAL_MODULE" \
        -target "$CODEGRAM_MATERIAL_TARGET" -sdk "$CODEGRAM_MATERIAL_SDK" \
        -emit-module-path "$CODEGRAM_MATERIAL_MODULES/$CODEGRAM_MATERIAL_MODULE.swiftmodule" \
        "$CODEGRAM_MATERIAL_STUBS/Empty.swift"
done
if ! xcrun --sdk iphonesimulator swiftc -parse-as-library -warnings-as-errors \
    -target "$CODEGRAM_MATERIAL_TARGET" -sdk "$CODEGRAM_MATERIAL_SDK" \
    -I "$CODEGRAM_MATERIAL_MODULES" -L "$CODEGRAM_MATERIAL_APP/Frameworks" \
    -lDisplay -lComponentFlow -lUIKitRuntimeUtils \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    "$CODEGRAM_MATERIAL_OUT/GlassBackgroundView.production.swift" \
    submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/ClassicGlassMaterialView.swift \
    "$CODEGRAM_MATERIAL_STUBS/UnusedLegacyRenderers.swift" \
    tools/nikita/tests/ModernMaterialUIHarness.swift \
    -o "$CODEGRAM_MATERIAL_APP/ModernMaterialHarness" > "$CODEGRAM_MATERIAL_OUT/swift-build.log" 2>&1; then
    cat "$CODEGRAM_MATERIAL_OUT/swift-build.log"
    exit 1
fi
for CODEGRAM_MATERIAL_LIBRARY in "$CODEGRAM_MATERIAL_APP"/Frameworks/*.dylib; do
    codesign --force --sign - "$CODEGRAM_MATERIAL_LIBRARY"
done
codesign --force --sign - "$CODEGRAM_MATERIAL_APP"
xcrun simctl list runtimes --json > "$CODEGRAM_MATERIAL_OUT/runtimes.json"
CODEGRAM_MATERIAL_RUNTIME=$(python3 - "$CODEGRAM_MATERIAL_OUT/runtimes.json" <<'PY'
import json, sys
standard = {'iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro'}
rows = [r for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and r.get('platform') == 'iOS' and int(r['version'].split('.')[0]) >= 26 and any(d['name'] in standard for d in r.get('supportedDeviceTypes', []))]
if not rows:
    raise SystemExit('Material UI checks need an installed iOS 26+ Simulator runtime')
print(max(rows, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier'])
PY
)
CODEGRAM_MATERIAL_DEVICE=$(python3 - "$CODEGRAM_MATERIAL_OUT/runtimes.json" "$CODEGRAM_MATERIAL_RUNTIME" <<'PY'
import json, sys
runtime = next(r for r in json.load(open(sys.argv[1]))['runtimes'] if r['identifier'] == sys.argv[2])
for name in ['iPhone 18 Pro Max', 'iPhone 17 Pro Max', 'iPhone 16 Pro Max', 'iPhone 17 Pro', 'iPhone 16 Pro']:
    found = next((d for d in runtime['supportedDeviceTypes'] if d['name'] == name), None)
    if found:
        print(found['identifier'])
        break
else:
    raise SystemExit('No supported iPhone Simulator device type')
PY
)
CODEGRAM_MATERIAL_SIM=$(xcrun simctl create "CodeGram material ${GITHUB_RUN_ID:-local}" "$CODEGRAM_MATERIAL_DEVICE" "$CODEGRAM_MATERIAL_RUNTIME")
xcrun simctl boot "$CODEGRAM_MATERIAL_SIM"
xcrun simctl bootstatus "$CODEGRAM_MATERIAL_SIM" -b
xcrun simctl install "$CODEGRAM_MATERIAL_SIM" "$CODEGRAM_MATERIAL_APP"
CODEGRAM_MATERIAL_DATA=$(xcrun simctl get_app_container "$CODEGRAM_MATERIAL_SIM" com.codegram.ModernMaterialFixture data)
xcrun simctl status_bar "$CODEGRAM_MATERIAL_SIM" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl io "$CODEGRAM_MATERIAL_SIM" recordVideo --codec=h264 --force "$CODEGRAM_MATERIAL_OUT/modern-material.mp4" > "$CODEGRAM_MATERIAL_OUT/recording.log" 2>&1 &
CODEGRAM_MATERIAL_REC=$!
python3 - "$CODEGRAM_MATERIAL_OUT/recording.log" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(100):
    if path.exists() and 'Recording started' in path.read_text():
        break
    time.sleep(.1)
else:
    raise SystemExit('Simulator recording did not start')
PY
CODEGRAM_MATERIAL_LAUNCH=$(xcrun simctl launch --stdout="$CODEGRAM_MATERIAL_OUT/console.log" --stderr="$CODEGRAM_MATERIAL_OUT/stderr.log" "$CODEGRAM_MATERIAL_SIM" com.codegram.ModernMaterialFixture)
printf '%s\n' "$CODEGRAM_MATERIAL_LAUNCH"
python3 - "$CODEGRAM_MATERIAL_SIM" "$CODEGRAM_MATERIAL_DATA/Documents" "$CODEGRAM_MATERIAL_OUT" "$CODEGRAM_MATERIAL_LAUNCH" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys, time
sim, documents, output = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
match = re.search(r':\s*(\d+)\s*$', sys.argv[4])
if not match:
    raise SystemExit('Simulator launch did not return the material harness PID: ' + sys.argv[4])
pid = int(match.group(1))
seen, timeline = set(), []
started = time.monotonic()
while time.monotonic() - started < 300:
    result = documents / 'result.json'
    if result.exists():
        shutil.copyfile(result, output / 'result.json')
        (output / 'timeline.json').write_text(json.dumps(timeline, indent=2) + '\n')
        report = json.loads(result.read_text())
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['failures'] or report['checks'] < 70 or report['classic_layout'] or report['glass_effects']:
            raise SystemExit('Production modern-material UI checks failed')
        required = {'01-modern-material-dark', '02-modern-material-light'}
        if seen != required or any(not (output / (phase + '.png')).is_file() for phase in required):
            raise SystemExit('Missing modern-material dark/light screenshot')
        break
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit('Material harness exited before result.json; inspect console/stderr logs')
    phase_path = documents / 'phase.txt'
    phase = phase_path.read_text() if phase_path.exists() else ''
    if phase and phase not in seen:
        seen.add(phase)
        detected = round(time.monotonic() - started, 3)
        time.sleep(.5)
        subprocess.run(['xcrun', 'simctl', 'io', sim, 'screenshot', str(output / (phase + '.png'))], check=True)
        timeline.append(dict(phase=phase, phase_seen_after_launch=detected, seconds_after_launch=round(time.monotonic() - started, 3)))
        (documents / ('captured-' + phase)).touch()
    time.sleep(.25)
else:
    raise SystemExit('Native material fixture did not finish')
PY
