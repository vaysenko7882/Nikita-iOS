import Foundation

// Native SwiftSignalKit retains closure contexts using swift_retain/release.
// A genuine native Swift object provides the expected heap header and lifetime.
// The two callbacks may share this immutable context safely.
private final class PreviewContext {
    let giftId: Int64
    let identifier: UInt64

    init(giftId: Int64, identifier: UInt64) {
        self.giftId = giftId
        self.identifier = identifier
    }
}

// Owns +1. Keep this reference through the native Signal.start call, then pass
// it to SGPreviewReleaseContext. Native callback closures keep their own refs.
@_cdecl("SGPreviewCreateContext")
public func SGPreviewCreateContext(_ giftId: Int64, _ identifier: UInt64) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(PreviewContext(giftId: giftId, identifier: identifier)).toOpaque()
}

@_cdecl("SGPreviewReleaseContext")
public func SGPreviewReleaseContext(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<PreviewContext>.fromOpaque(pointer).release()
}

// The native .S adapter remaps Swift x20 (context) to C x1. The next-value
// pointer is borrowed from SwiftSignalKit and must not escape this function.
@_cdecl("SGPreviewConsumeValue")
public func SGPreviewConsumeValue(_ value: UnsafeRawPointer?, _ pointer: UnsafeRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<PreviewContext>.fromOpaque(pointer).takeUnretainedValue()
    let json = SGCatalogCopyPreviewJSON(value, context.giftId)
    SGPreviewResult(context.identifier, json)
    if let json { free(json) }
}

// The native .S adapter remaps Swift x20 (context) to C x0.
@_cdecl("SGPreviewConsumeComplete")
public func SGPreviewConsumeComplete(_ pointer: UnsafeRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<PreviewContext>.fromOpaque(pointer).takeUnretainedValue()
    SGPreviewFinished(context.identifier)
}
