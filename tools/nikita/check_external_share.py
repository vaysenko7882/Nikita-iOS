#!/usr/bin/env python3
"""Inject resource failures into the production external-share collector."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    source = (ROOT / "submodules/ShareController/Sources/ShareController.swift").read_text()
    collector = source[source.index("private enum ExternalShareResourceStatus {"):
        source.index("\nprivate enum ExternalShareItemsState {")]
    with tempfile.TemporaryDirectory(prefix="codegram-external-share-") as directory:
        directory = Path(directory)
        generated = directory / "ExternalShareResourceCheck.swift"
        generated.write_text("import Foundation\n" + collector + "\n" +
            (ROOT / "tools/nikita/tests/ExternalShareResourceCheck.swift").read_text())
        signal_sources = ROOT / "submodules/SSignalKit/SwiftSignalKit/Source"
        # The collector runs the real signal/subscriber/disposal implementation;
        # only the network and MediaBox event producers are controlled by the test.
        sources = [signal_sources / (name + ".swift") for name in
            ("Atomic", "Disposable", "Subscriber", "Signal", "Signal_Take")]
        executable = directory / "external-share-check"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", *map(str, sources),
            str(generated), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
