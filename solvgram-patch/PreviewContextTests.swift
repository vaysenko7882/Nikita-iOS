#if SG_PREVIEW_CONTEXT_TEST
import Foundation

private final class WeakContext {
    weak var value: AnyObject?

    init(_ pointer: UnsafeMutableRawPointer) {
        value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

@main
private enum PreviewContextTests {
    static func main() {
        let pointer = SGPreviewCreateContext(123, 456)
        let weakContext = WeakContext(pointer)
        // Match two native callback-closure retains, then drop the initial +1.
        let nextOwner = Unmanaged<AnyObject>.fromOpaque(pointer).retain()
        let completedOwner = Unmanaged<AnyObject>.fromOpaque(pointer).retain()
        SGPreviewReleaseContext(pointer)
        precondition(weakContext.value != nil)
        SGPreviewConsumeValue(nil, pointer)
        precondition(SGPreviewTestResultCount() == 1)
        precondition(SGPreviewTestIdentifier() == 456)
        precondition(SGPreviewTestJSONWasNull() == 1)
        nextOwner.release()
        precondition(weakContext.value != nil)
        SGPreviewConsumeComplete(pointer)
        precondition(SGPreviewTestFinishedCount() == 1)
        precondition(SGPreviewTestIdentifier() == 456)
        completedOwner.release()
        precondition(weakContext.value == nil)

        SGPreviewConsumeValue(nil, nil)
        SGPreviewConsumeComplete(nil)
        SGPreviewReleaseContext(nil)
        precondition(SGPreviewTestResultCount() == 1)
        precondition(SGPreviewTestFinishedCount() == 1)
        print("Native preview context lifetime tests passed")
    }
}
#endif
