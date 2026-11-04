This fixture compiles the unchanged production source prefix of GlassBackgroundComponent.swift, stopping immediately before its ComponentFlow wrapper. That prefix contains the actual GlassBackgroundView, GlassBackgroundContainerView, shape definitions, clipping context, update paths, and drawing helpers. It also compiles the real ClassicGlassMaterialView.swift and ClassicDesign.swift.

The stand-ins only provide immediate transition property setters, Display color/image helpers, import-only modules, and signatures needed to typecheck inactive renderers. Native and legacy sampled-renderer constructors and backdrop-filter factories trap if called. No material view, frame calculation, shape, clipping implementation, or corner-radius calculation is mocked.

The baseline JSON fingerprints the exact shape/clipping source and layout assignments from commit 94ef262d387a36d3409f317b4d29bdb9044067c2. The runner rejects a geometry change before compiling.

These isolated UIKit screenshots check circles, pills, symmetric and asymmetric panels, navigation groups, opaque surfaces, and theme updates. They do not replace a full Telegram Bazel build, account-based integration tests, animation-timing tests, or physical-device energy measurements.
