import Foundation
import CoreFoundation

// Cancellation can arrive before SGReviewGiftSend has returned its operation,
// including before the continuation body starts. Keep both states under one lock.
private final class SGGiftAsyncOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: AnyObject?
    private var cancelled = false
    private var cancellationDelivered = false
    private var completed = false

    func install(_ operation: AnyObject) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        self.operation = operation
        let shouldCancel = cancelled && !cancellationDelivered
        if shouldCancel { cancellationDelivered = true }
        lock.unlock()
        if shouldCancel { SGCancelGiftSend(operation) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = !completed && !cancellationDelivered ? operation : nil
        if target != nil { cancellationDelivered = true }
        lock.unlock()
        if let target { SGCancelGiftSend(target) }
    }

    // Also guards a continuation against an erroneous duplicate callback.
    func finish() -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let finishedOperation = operation
        operation = nil
        lock.unlock()
        withExtendedLifetime(finishedOperation) {}
        return true
    }
}

private func sgGiftRequest(_ request: URLRequest) -> Bool {
    guard let url = request.url,
          url.host?.lowercased() == "archive.2.26.254.34.sslip.io",
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          url.path.hasPrefix("/v1/pro/gifts/") else { return false }
    return !url.pathComponents.contains(where: { $0 == "." || $0 == ".." })
}

private func sgGiftSendRequest(_ request: URLRequest) -> Bool {
    guard request.httpMethod?.uppercased() == "POST",
          request.url?.path == "/v1/pro/gifts/send",
          let data = request.httpBody,
          let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    // The original native sender serializes both identifiers as decimal strings.
    // Leave unrelated or malformed requests on Foundation's original path.
    func validIdentifier(_ value: Any?) -> Bool {
        if let value = value as? String { return Int64(value) != nil }
        if let value = value as? NSNumber {
            return CFGetTypeID(value) != CFBooleanGetTypeID() &&
                Int64(value.stringValue) != nil
        }
        return false
    }
    return validIdentifier(body["gift"]) && validIdentifier(body["to"])
}

private func sgRewriteGiftData(_ data: Data) -> Data {
    return (SGRewriteGiftResponseObject(data as NSData) as? Data) ?? data
}

extension URLSession {
    // IMPORTANT: This method's Swift async calling convention, including the
    // implicit URLSession self argument, matches Foundation's data(for:delegate:).
    // Core's function import AND async-context descriptor (SGSessionDataTu) must
    // both be rebound. This dylib's own Foundation import stays untouched.
    @_silgen_name("SGSessionData")
    public func sgGiftData(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse) {
        guard sgGiftRequest(request) else {
            return try await self.data(for: request, delegate: delegate)
        }

        if !sgGiftSendRequest(request) {
            let (data, response) = try await self.data(for: request, delegate: delegate)
            return (sgRewriteGiftData(data), response)
        }

        let operation = SGGiftAsyncOperation()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handle = SGReviewGiftSendObject(self, request as NSURLRequest) { data, response, error in
                    guard operation.finish() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data as Data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                operation.install(handle as AnyObject)
            }
        } onCancel: {
            operation.cancel()
        }
        return (sgRewriteGiftData(result.0), result.1)
    }
}
