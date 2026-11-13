import Foundation

// The private cache is a native Swift object. Its dynamic metadata is retained
// in this IPA, so reflection does not require importing TelegramCore.
private func property(_ value: Any, _ name: String) -> Any? {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
        for child in current.children where child.label == name {
            return child.value
        }
        mirror = current.superclassMirror
    }
    return nil
}

private func catalog(_ cache: AnyObject, giftId: Int64) -> [String: Any]? {
    guard let lock = property(cache, "lock") as? NSLock else {
        return nil
    }
    // Copy the dictionary while holding the very lock the original app uses.
    // The dictionary value retains its storage; subsequent writes use COW.
    lock.lock()
    let previewDictionary = property(cache, "previews")
    lock.unlock()
    guard let previewDictionary else { return nil }

    var preview: Any?
    for item in Mirror(reflecting: previewDictionary).children {
        let tuple = Array(Mirror(reflecting: item.value).children)
        guard tuple.count == 2, let key = tuple[0].value as? Int64 else { continue }
        if key == giftId {
            preview = tuple[1].value
            break
        }
    }
    guard let preview, let attributes = property(preview, "attributes") else { return nil }
    var models: [[String: Any]] = []
    var backdrops: [[String: Any]] = []
    var patterns: [[String: Any]] = []
    for attribute in Mirror(reflecting: attributes).children {
        let enumMirror = Mirror(reflecting: attribute.value)
        guard enumMirror.displayStyle == .enum,
              let variant = enumMirror.children.first,
              let kind = variant.label,
              let name = property(variant.value, "name") as? String else { continue }
        switch kind {
        case "model":
            models.append(["index": models.count, "name": name])
        case "backdrop":
            var entry: [String: Any] = ["index": backdrops.count, "name": name]
            for key in ["innerColor", "outerColor", "patternColor", "textColor"] {
                if let color = property(variant.value, key) as? Int32 {
                    entry[key] = Int64(UInt32(bitPattern: color))
                }
            }
            backdrops.append(entry)
        case "pattern":
            patterns.append(["index": patterns.count, "name": name])
        default: break
        }
    }
    guard !models.isEmpty || !backdrops.isEmpty else { return nil }
    return ["giftId": String(giftId), "models": models, "backdrops": backdrops, "patterns": patterns]
}

// Returned UTF-8 JSON is allocated with strdup. The Objective-C caller owns it
// and must free() it. NULL means there is no native preview cached for this gift.
@_cdecl("SGCatalogCopyJSON")
public func SGCatalogCopyJSON(_ cachePointer: UnsafeRawPointer?, _ giftId: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let cachePointer else { return nil }
    let cache = Unmanaged<AnyObject>.fromOpaque(cachePointer).takeUnretainedValue()
    guard let result = catalog(cache, giftId: giftId),
          JSONSerialization.isValidJSONObject(result),
          let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return strdup(string)
}

// Layout is pinned to the supplied Solvgram 1.2 (100063) arm64 binary:
// StarGiftUpgradePreview? is three array references, the first (attributes) is
// zero for nil. Native contiguous arrays have a 32-byte header. Attribute stride
// is 72 bytes; the case discriminator is bits 62...63 of payload word +40.
// Core 0x943b40...0x943e28 uses exactly these offsets when partitioning the same
// preview into model/pattern/backdrop arrays. All three named cases start with
// a native Swift.String. This callback must run synchronously while the native
// Signal next-value pointer is valid; it returns only independently owned JSON.
@_cdecl("SGCatalogCopyPreviewJSON")
public func SGCatalogCopyPreviewJSON(_ previewPointer: UnsafeRawPointer?, _ giftId: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let previewPointer else { return nil }
    let arrayAddress = previewPointer.load(as: UInt.self)
    guard arrayAddress > 4096, arrayAddress & 7 == 0,
          let array = UnsafeRawPointer(bitPattern: arrayAddress) else { return nil }
    let count = array.advanced(by: 16).load(as: UInt.self)
    guard count > 0, count <= 4096 else { return nil }

    var models: [[String: Any]] = []
    var backdrops: [[String: Any]] = []
    var patterns: [[String: Any]] = []
    for index in 0..<Int(count) {
        let item = array.advanced(by: 32 + 72 * index)
        let tag = item.advanced(by: 40).load(as: UInt64.self) >> 62
        guard tag <= 2 else { continue }
        // load(as:) copies the valid String value; normal Swift lifetime rules
        // retain its storage while JSONSerialization reads it.
        let name = item.load(as: String.self)
        let displayName = String(name.prefix(1024))
        switch tag {
        case 0: models.append(["index": models.count, "name": displayName.isEmpty ? "Модель №\(models.count + 1)" : displayName])
        case 1: patterns.append(["index": patterns.count, "name": displayName.isEmpty ? "Узор №\(patterns.count + 1)" : displayName])
        case 2: backdrops.append(["index": backdrops.count, "name": displayName.isEmpty ? "Фон №\(backdrops.count + 1)" : displayName])
        default: break
        }
    }
    guard !models.isEmpty || !backdrops.isEmpty else { return nil }
    let result: [String: Any] = ["giftId": String(giftId), "models": models, "backdrops": backdrops, "patterns": patterns]
    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return strdup(string)
}

#if SG_CATALOG_TEST
private enum MockAttribute {
    case model(name: String, file: String, rarity: Int, crafted: Bool)
    case pattern(name: String, file: String, rarity: Int)
    case backdrop(name: String, id: Int32, innerColor: Int32, outerColor: Int32, patternColor: Int32, textColor: Int32, rarity: Int)
    case originalInfo(senderPeerId: Int64?, recipientPeerId: Int64, date: Int32, text: String?)
}
private struct MockPreview {
    let attributes: [MockAttribute]
    let prices: [Int]
    let nextPrices: [Int]
}
private final class MockCache {
    let lock = NSLock()
    var collectibles: [String: String] = [:]
    var previews: [Int64: MockPreview] = [:]
    var editions: [Int64: Int32] = [:]
}
@main
private enum CatalogTests {
    static func main() {
        let cache = MockCache()
        cache.previews[123] = MockPreview(attributes: [
            .model(name: "Ice", file: "", rarity: 1, crafted: false),
            .pattern(name: "Stars", file: "", rarity: 2),
            .backdrop(name: "Чёрный", id: 2, innerColor: 0x112233, outerColor: 0x445566, patternColor: -1, textColor: 0, rarity: 3),
            .model(name: "Gold", file: "", rarity: 4, crafted: false),
            .originalInfo(senderPeerId: nil, recipientPeerId: 1, date: 1, text: nil)
        ], prices: [], nextPrices: [])
        let pointer = Unmanaged.passUnretained(cache).toOpaque()
        guard let json = SGCatalogCopyJSON(pointer, 123) else { fatalError("missing catalog") }
        defer { free(json) }
        let data = String(cString: json).data(using: .utf8)!
        let result = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = result["models"] as! [[String: Any]]
        let backdrops = result["backdrops"] as! [[String: Any]]
        precondition(models.count == 2 && models[1]["name"] as? String == "Gold")
        precondition(models[1]["index"] as? Int == 1)
        precondition(backdrops.count == 1 && backdrops[0]["name"] as? String == "Чёрный")
        precondition((backdrops[0]["patternColor"] as? NSNumber)?.uint64Value == 4294967295)
        precondition(SGCatalogCopyJSON(pointer, 999) == nil)
        precondition(SGCatalogCopyJSON(nil, 123) == nil)

        // Build only the pinned representation being consumed, independently
        // of this compiler's own enum layout. Dynamic String storage ownership
        // remains managed normally for each initialized field.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 32 + 72 * 4, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: 32 + 72 * 4)
        raw.advanced(by: 16).storeBytes(of: UInt(4), as: UInt.self)
        let cases: [(UInt64, String)] = [(0, "Ice"), (1, "Stars"), (2, "Чёрный длинный фон"), (0, "Gold")]
        for (index, item) in cases.enumerated() {
            let value = raw.advanced(by: 32 + 72 * index)
            value.assumingMemoryBound(to: String.self).initialize(to: item.1)
            value.advanced(by: 40).storeBytes(of: item.0 << 62, as: UInt64.self)
        }
        var arrayReference = UInt(bitPattern: raw)
        let rawJSON = withUnsafePointer(to: &arrayReference) { SGCatalogCopyPreviewJSON($0, 456) }
        guard let rawJSON else { fatalError("missing raw catalog") }
        let rawResult = try! JSONSerialization.jsonObject(with: String(cString: rawJSON).data(using: .utf8)!) as! [String: Any]
        precondition((rawResult["models"] as! [[String: Any]]).count == 2)
        precondition((rawResult["backdrops"] as! [[String: Any]])[0]["name"] as? String == cases[2].1)
        free(rawJSON)
        raw.advanced(by: 16).storeBytes(of: UInt(4097), as: UInt.self)
        precondition(withUnsafePointer(to: &arrayReference) { SGCatalogCopyPreviewJSON($0, 456) } == nil)
        raw.advanced(by: 16).storeBytes(of: UInt(0), as: UInt.self)
        precondition(withUnsafePointer(to: &arrayReference) { SGCatalogCopyPreviewJSON($0, 456) } == nil)
        for index in cases.indices {
            raw.advanced(by: 32 + 72 * index).assumingMemoryBound(to: String.self).deinitialize(count: 1)
        }
        raw.deallocate()
        print("Catalog reflection tests passed")
    }
}
#endif
