import Foundation

private final class SGShimProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.query == "fail=1" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: SGShimTestResponseData() as Data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private enum SGSessionShimTests {
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    private static func styled(_ data: Data) throws -> Bool {
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let unique = value["unique"] as! [String: Any]
        return (unique["model"] as? Int) == 8 && (unique["backdrop"] as? Int) == 9
    }
    private static func send() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://archive.2.26.254.34.sslip.io/v1/pro/gifts/send")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"gift":"123","to":"456","hidden":false,"upgrade":true}"#.utf8)
        return request
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SGShimProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            UserDefaults.standard.removeObject(forKey: "SGGiftControls.AppearanceByGiftID.v1")
        }
        SGShimTestSetMode(0)
        let plain = URLRequest(url: URL(string: "https://example.invalid/native")!)
        let (plainData, _) = try await session.sgGiftData(for: plain, delegate: nil)
        check(plainData == SGShimTestResponseData() as Data, "Unmatched request was rewritten")
        check(SGShimTestReviewCalls() == 0, "Unmatched request entered gift review")

        let list = URLRequest(url: URL(string: "https://archive.2.26.254.34.sslip.io/v1/pro/gifts/sent?limit=50")!)
        let (listData, _) = try await session.sgGiftData(for: list, delegate: nil)
        check(try styled(listData), "Gift list was not rewritten")
        check(SGShimTestReviewCalls() == 0, "Gift fetch entered send review")

        let (sendData, _) = try await session.sgGiftData(for: send(), delegate: nil)
        check(try styled(sendData), "Reviewed send result was not rewritten")
        check(SGShimTestReviewCalls() == 1, "Valid send did not enter review exactly once")

        var malformed = send()
        malformed.httpBody = Data(#"{"gift":"123","to":true}"#.utf8)
        _ = try await session.sgGiftData(for: malformed, delegate: nil)
        check(SGShimTestReviewCalls() == 1, "Malformed send entered review")

        for (mode, code) in [(1, URLError.Code.timedOut), (2, .badServerResponse)] {
            SGShimTestSetMode(mode)
            do {
                _ = try await session.sgGiftData(for: send(), delegate: nil)
                preconditionFailure("Invalid reviewer result unexpectedly succeeded")
            } catch let error as URLError {
                check(error.code == code, "Wrong reviewer error")
            }
        }
        for mode in [3, 4] {
            SGShimTestSetMode(mode)
            let operation = Task { try await session.sgGiftData(for: send(), delegate: nil) }
            while SGShimTestReviewCalls() == 0 { await Task.yield() }
            operation.cancel()
            do {
                _ = try await operation.value
                preconditionFailure("Cancelled send unexpectedly succeeded")
            } catch let error as URLError {
                check(error.code == .cancelled, "Wrong cancellation error")
            }
            check(SGShimTestCancelCalls() == 1, "Cancellation was lost or duplicated")
        }
        SGShimTestSetMode(5)
        _ = try await session.sgGiftData(for: send(), delegate: nil)
        check(SGShimTestReviewCalls() == 1, "Duplicate callback test did not run")

        let failing = URLRequest(url: URL(string: "https://example.invalid/native?fail=1")!)
        do {
            _ = try await session.sgGiftData(for: failing, delegate: nil)
            preconditionFailure("Original transport failure unexpectedly succeeded")
        } catch let error as URLError {
            check(error.code == .cannotConnectToHost, "Original transport error was changed")
        }
        print("SessionShim: forwarding, rewriting, review, error, cancellation and duplicate-callback checks passed")
    }
}
