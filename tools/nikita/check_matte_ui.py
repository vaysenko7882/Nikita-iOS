#!/usr/bin/env python3
"""Keep app-owned Liquid Glass out of the matte fork.

The existing upstream renderer remains compiled for ABI/source compatibility,
but immutable GlassEffects prevents creating its native/legacy glass branches
while ClassicDesign stays disabled, retaining modern layout and shape geometry. New direct glass or system-alert factories must not bypass that policy.
OS-owned pickers and share extensions are outside this source guard's scope.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SHARED_GLASS = "submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift"


def check(root=ROOT, overlay=None):
    def source(relative):
        candidate = overlay / relative if overlay else None
        return (candidate if candidate and candidate.exists() else root / relative).read_text()

    problems = []
    policy = source("submodules/Display/Source/ClassicDesign.swift")
    if not re.search(r"get\s*\{\s*return false\s*\}\s*set\s*\{\s*\}", policy):
        problems.append("ClassicDesign must stay disabled to preserve modern layout")
    if not re.search(r"public enum GlassEffects\s*\{[\s\S]*?static var isEnabled:\s*Bool\s*\{\s*return false\s*\}", policy):
        problems.append("GlassEffects must independently disable optical material")
    if "configureWithOpaqueBackground()" in policy or "isTranslucent = false" in policy:
        problems.append("Opaque material must not force legacy UIKit layout")
    bootstrap = source("submodules/TelegramUI/Sources/AppDelegate.swift")
    if "ClassicDesign.installOpaqueSystemAppearance()" not in bootstrap:
        problems.append("App bootstrap must install the opaque public UIKit appearances")
    item_proxy = source("submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UINavigationItem+Proxy.m")
    if "item.hidesSharedBackground = YES" not in item_proxy or "item.sharesBackground = NO" not in item_proxy or item_proxy.count("codeGramMakeBarButtonMatte(") < 6:
        problems.append("Native left/right/back bar items must suppress their shared glass background")
    glass = source(SHARED_GLASS)
    if glass.count("if !GlassEffects.isEnabled {") < 3:
        problems.append("Shared constructors/container must use their shape-preserving flat material")

    gates = {
        "submodules/TelegramUI/Components/LiquidLens/Sources/LiquidLensView.swift": "#available(iOS 26.0, *), GlassEffects.isEnabled",
        "submodules/TelegramUI/Components/LiquidGlassShapes/Sources/LiquidGlassShapesLayer.swift": "wantsGlass = !self.isFlat && GlassEffects.isEnabled",
        "submodules/TelegramUI/Components/LensTransition/Sources/LiquidMorphTransition.swift": "return GlassEffects.isEnabled && LTTransitionDriver.isSupported()",
    }
    for path, gate in gates.items():
        if gate not in source(path):
            problems.append(path + ": glass/lens/refraction must honor the matte policy")

    checked = 0
    factory = re.compile(r"\b(?:UIGlassEffect|UIGlassContainerEffect)\s*(?:\.\s*init\s*)?\(")
    native_alert = re.compile(r"\bUIAlertController\s*(?:\.\s*init\s*)?\(")
    swiftui_glass = re.compile(r"\.glassEffect\s*\(")
    button_glass = re.compile(r"UIButton\.Configuration\.(?:glass|prominentGlass|glassProminent)\s*\(|\.buttonStyle\(\s*\.glass(?:Prominent)?\b")
    paths = set()
    for base in (root, overlay):
        if base:
            for directory in (base / "Telegram", base / "submodules"):
                paths.update(path.relative_to(base).as_posix() for path in directory.rglob("*") if path.suffix in {".swift", ".m", ".mm"})
    for relative in sorted(paths):
        path = Path(relative)
        # Test/demo oracles deliberately describe platform behavior. They
        # are not app-owned production entry points.
        if any(part in {"Tests", "Demo", "Host"} for part in path.parts):
            continue
        text = source(relative)
        checked += 1
        if relative != SHARED_GLASS and factory.search(text):
            problems.append(relative + ": direct native glass factory")
        if relative == SHARED_GLASS and len(factory.findall(text)) != 3:
            problems.append(relative + ": unexpected shared native glass factory count")
        if native_alert.search(text):
            problems.append(relative + ": system alert bypasses the matte dialog")
        if re.search(r"\[\s*(?:UIGlassEffect|UIGlassContainerEffect)\s+(?:alloc|effectWithStyle:)", text):
            problems.append(relative + ": direct Objective-C glass factory")
        if re.search(r"\[\s*UIAlertController\s+(?:alloc|alertControllerWithTitle:)", text):
            problems.append(relative + ": Objective-C system alert bypasses the matte dialog")
        if swiftui_glass.search(text) or button_glass.search(text):
            problems.append(relative + ": direct SwiftUI/button glass effect")
    return checked, problems


if __name__ == "__main__":
    count, failures = check(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT,
                            Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print(f"Matte UI policy checked {count} production source files; no direct glass or system-alert bypasses.")
