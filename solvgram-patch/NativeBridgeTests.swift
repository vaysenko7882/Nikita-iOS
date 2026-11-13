#if SG_NATIVE_BRIDGE_TEST
import Foundation

public enum SGTestNoError {}

// The optional's first zero pointer is its nil extra inhabitant, just like the
// native three-array StarGiftUpgradePreview? passed by SwiftSignalKit.
public struct SGTestPreview {
    let attributes: UnsafeRawPointer
    let prices: UnsafeRawPointer?
    let nextPrices: UnsafeRawPointer?
}

public protocol SGTestDisposable: AnyObject {
    func dispose()
}

private var nativeDisposableDeaths = 0
private var nativeDisposableDisposals = 0
private final class SGTestOwnedDisposable: SGTestDisposable {
    private var disposed = false
    private var action: (() -> Void)?

    init(action: @escaping () -> Void) { self.action = action }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        nativeDisposableDisposals += 1
        let action = self.action
        self.action = nil
        action?()
    }
    deinit { nativeDisposableDeaths += 1 }
}

// Keep this genuinely generic: the native next-value callback passes a borrowed
// pointer to T, rather than a concrete three-word struct in x0/x1/x2.
public final class SGTestSignal<T, E> {
    let value: T
    var next: ((T) -> Void)?
    var completed: (() -> Void)?

    init(value: T) { self.value = value }

    @_silgen_name("SGTestSignalStart")
    public func start(next: ((T) -> Void)?, error: ((E) -> Void)?, completed: (() -> Void)?) -> any SGTestDisposable {
        precondition(self.next == nil && self.completed == nil)
        self.next = next
        self.completed = completed
        return SGTestOwnedDisposable {
            self.next = nil
            self.completed = nil
        }
    }

    @inline(never)
    func fire() {
        next?(value)
        completed?()
        next = nil
        completed = nil
    }
}

private final class SGTestWeakContext {
    weak var object: AnyObject?
    init(_ pointer: UnsafeMutableRawPointer) {
        object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

@main
private enum NativeBridgeTests {
    static func run<T>(_ value: T, giftId: Int64, identifier: UInt64, cancel: Bool = false) -> SGTestSignal<T, SGTestNoError> {
        let signal = SGTestSignal<T, SGTestNoError>(value: value)
        let context = SGPreviewCreateContext(giftId, identifier)
        let weakContext = SGTestWeakContext(context)
        let pair = SGNativeStart(Unmanaged.passUnretained(signal).toOpaque(),
                                 SGTestNextAddress(), SGTestCompletedAddress(),
                                 context, SGTestSignalStartAddress())
        precondition(pair.object != nil && pair.witness != nil)
        SGPreviewReleaseContext(context)
        precondition(weakContext.object != nil, "native closures did not retain context")
        let disposalsBefore = nativeDisposableDisposals
        if cancel {
            // Exercise exactly the timeout/cancel path: call the first protocol
            // requirement via witness+8 before any callback is fired.
            SGNativeDispose(pair.object!, pair.witness!)
            precondition(weakContext.object == nil, "dispose did not release native callbacks")
            signal.fire() // Cleared callback fields must produce no result.
        } else {
            signal.fire()
            precondition(weakContext.object == nil, "native closures leaked context")
            SGNativeDispose(pair.object!, pair.witness!)
        }
        precondition(nativeDisposableDisposals == disposalsBefore + 1,
                     "witness disposal did not dispatch to Swift instance method")
        // Swift's class-bound existential return gives C an owned object word.
        Unmanaged<AnyObject>.fromOpaque(pair.object!).release()
        return signal
    }

    static func main() {
        precondition(MemoryLayout<SGTestPreview?>.size == 24)
        let array = UnsafeMutableRawPointer.allocate(byteCount: 32 + 72 * 3, alignment: 16)
        array.initializeMemory(as: UInt8.self, repeating: 0, count: 32 + 72 * 3)
        array.advanced(by: 16).storeBytes(of: UInt(3), as: UInt.self)
        for (index, item) in [(UInt64(0), "Ice"), (UInt64(1), "Stars"), (UInt64(2), "Тёмный фон")].enumerated() {
            let pointer = array.advanced(by: 32 + 72 * index)
            pointer.assumingMemoryBound(to: String.self).initialize(to: item.1)
            pointer.advanced(by: 40).storeBytes(of: item.0 << 62, as: UInt64.self)
        }
        let preview = SGTestPreview(attributes: UnsafeRawPointer(array), prices: nil, nextPrices: nil)
        _ = run(Optional.some(preview), giftId: 123, identifier: 456)
        precondition(SGNativeBridgeResultCount() == 1 && SGNativeBridgeFinishedCount() == 1)
        precondition(SGNativeBridgeIdentifier() == 456)
        guard let json = SGNativeBridgeLastJSON() else { fatalError("raw preview callback returned no JSON") }
        let result = try! JSONSerialization.jsonObject(with: String(cString: json).data(using: .utf8)!) as! [String: Any]
        precondition(result["giftId"] as? String == "123")
        precondition((result["models"] as! [[String: Any]])[0]["name"] as? String == "Ice")
        precondition((result["backdrops"] as! [[String: Any]])[0]["name"] as? String == "Тёмный фон")
        precondition(nativeDisposableDeaths == 1)
        precondition(nativeDisposableDisposals == 1)

        _ = run(Optional<SGTestPreview>.none, giftId: 124, identifier: 789)
        precondition(SGNativeBridgeResultCount() == 2 && SGNativeBridgeFinishedCount() == 2)
        precondition(SGNativeBridgeIdentifier() == 789 && SGNativeBridgeLastJSON() == nil)
        precondition(nativeDisposableDeaths == 2)
        precondition(nativeDisposableDisposals == 2)

        _ = run(Optional.some(preview), giftId: 125, identifier: 1000, cancel: true)
        precondition(SGNativeBridgeResultCount() == 2 && SGNativeBridgeFinishedCount() == 2,
                     "cancelled subscription delivered a callback")
        precondition(nativeDisposableDeaths == 3 && nativeDisposableDisposals == 3)
        SGNativeBridgeResetJSON()

        for index in 0..<3 {
            array.advanced(by: 32 + 72 * index).assumingMemoryBound(to: String.self).deinitialize(count: 1)
        }
        array.deallocate()
        print("Native .S bridge and Swift callback ownership tests passed")
    }
}
#endif
