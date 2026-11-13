Solvgram 1.2 (100063): gift controls patch source

Status: source prepared; native compilation and iPhone execution are pending.
Original IPA SHA-256:
c8633511d6682f80a9a5ba0e81736cf2fd512dbb4b2f0ee6ed78493397ef16d3

Intended behavior:
- An extra form before phantom gift sends, quantity 1..1000.
- Independent model and backdrop choices from the app's Telegram upgrade preview; either may remain random.
- Bounded batching, cancellation, actual success counts, local phantom Stars debit/refund for extra gifts.
- Local profile badge text "настоящий владелец" for 7100373090.

Implementation:
- Compiled ARM64 Swift/Objective-C dylib plus narrow, version-pinned static patches.
- Core's URLSession.data(for:delegate:) function and async descriptor imports are rebound to an ABI-matching Swift method in the added dylib.
- Real Telegram requests continue through Foundation unchanged. Only the existing Solvgram phantom gift endpoint is handled specially.
- Fixed appearance choices use validated styling metadata in the existing gift text field and a local per-gift fallback. Human text is preserved; a fixed style supports up to 99 UTF-16 units. Appearance is interpreted by patched clients.
- The backend receives individual requests; it may stop before 1000 because of its own limits. Progress reports actual successes and does not silently retry failed requests.
- Native per-gift history ledger records the original send; additional local balance changes are maintained by the patch.

Completed local validation:
- Badge machine code: 17 ARM64 instruction-execution cases in Unicorn.
- Gift instrumentation and renderer branches: emulated at zero and realistic ASLR slides.
- Packaging: ZIP integrity, Mach-O parsing, preserved resources/permissions, precise header-only dependency/signature edits.
- Python/shell syntax checks.

Prepared native tests (not yet executed):
- Swift catalog extraction/reflection, Unicode and array layout.
- Real generic Swift callback ABI, context ownership, disposal and cancellation.
- Request schema preservation, independent styles, metadata checksum/text limits, response persistence.
- Async transport shim forwarding/cancellation tests.

Build:
Use build.sh on an ARM64 macOS runner with Xcode 27. The workflow example targets the connected account's existing xcode-27 runner.
Only patch source and the build workflow are needed on GitHub; this archive contains no original IPA, account token, certificate, or signing key.
The user signs the resulting IPA after packaging. Launch and visual behavior on an iPhone remain to be verified.
