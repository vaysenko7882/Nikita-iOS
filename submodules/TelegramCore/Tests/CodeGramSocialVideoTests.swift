import Foundation
import XCTest
@testable import TelegramCore

final class CodeGramSocialVideoTests: XCTestCase {
    func testOnlySupportedStandaloneVideoLinksConvert() {
        for text in ["https://www.tiktok.com/@owner/video/123", "https://vm.tiktok.com/Ab12/", "https://vt.tiktok.com/Ab12/", "https://www.instagram.com/reel/Ab_-12/", "https://instagram.com/p/Ab123/", " https://instagram.com/tv/Ab123/?igsh=x\n"] {
            XCTAssertNotNil(CodeGramSocialVideoLink.url(in: text),text)
        }
        for text in ["http://www.instagram.com/reel/1/", "https://instagram.com.evil/reel/1/", "https://instagram.com@127.0.0.1/reel/1/", "https://user:pass@instagram.com/reel/1/", "https://instagram.com:80/reel/1/", "https://instagram.com/stories/user/1/", "https://www.tiktok.com/@user", "Watch https://instagram.com/reel/1/", "https://instagram.com/reel/1/ https://instagram.com/reel/2/", "file:///etc/passwd", "https://127.0.0.1/reel/1/", "https://instagram.com/reel/%2e%2e/", ""] {
            XCTAssertNil(CodeGramSocialVideoLink.url(in: text),text)
        }
    }
    func testTrackingQueryAndFragmentNeverReachVPS() {
        XCTAssertEqual(CodeGramSocialVideoLink.url(in: "https://m.instagram.com/reel/ABC/?igsh=private#fragment")?.absoluteString,"https://www.instagram.com/reel/ABC/")
        XCTAssertEqual(CodeGramSocialVideoLink.url(in: "https://tiktok.com/@owner/video/123?share=private")?.absoluteString,"https://www.tiktok.com/@owner/video/123")
        XCTAssertEqual(CodeGramSocialVideoLink.url(in: "https://tiktok.com/t/ZP8abc_/?share=private")?.absoluteString,"https://www.tiktok.com/t/ZP8abc_/")
    }
    func testVideoUsesNormalTemporaryFileUploaderAndStreamingAttribute() {
        let media = codegramSocialVideoMedia(path: "/tmp/test-video.mp4",size: 123,duration: 2.5,width: 720,height: 1280)
        XCTAssertEqual(media.mimeType,"video/mp4")
        XCTAssertEqual(media.size,123)
        guard let resource = media.resource as? LocalFileReferenceMediaResource else { return XCTFail("Missing native file reference") }
        XCTAssertTrue(resource.isUniquelyReferencedTemporaryFile)
        XCTAssertEqual(resource.localFilePath,"/tmp/test-video.mp4")
        var found = false
        for attribute in media.attributes {
            if case let .Video(duration,dimensions,flags,_,_,_) = attribute {
                found = true
                XCTAssertEqual(duration,2.5);XCTAssertEqual(dimensions.width,720);XCTAssertEqual(dimensions.height,1280)
                XCTAssertTrue(flags.contains(.supportsStreaming))
            }
        }
        XCTAssertTrue(found)
    }
    func testSharedVideoURLsNormalizeWithoutTrackingOrCredentials() {
        let examples = [
            "https://instagram.com/owner.name/reel/Ab_12/?igsh=tracking": "https://instagram.com/reel/Ab_12/",
            "https://www.instagram.com/reels/Ab-12/": "https://www.instagram.com/reel/Ab-12/",
            "https://m.instagram.com/owner/p/Ab123/": "https://www.instagram.com/p/Ab123/",
            "https://instagram.com/share/reel/Ab123/?igsh=tracking": "https://instagram.com/share/reel/Ab123/",
            "https://www.tiktok.com/share/video/123456?share=tracking": "https://www.tiktok.com/share/video/123456"
        ]
        for (input, expected) in examples { XCTAssertEqual(CodeGramSocialVideoLink.url(in: input)?.absoluteString, expected, input) }
        for input in ["https://instagram.com/owner/unknown/123/", "https://instagram.com/owner/reel/123/extra", "https://instagram.com/share/stories/123/", "https://instagram.com.evil/share/reel/123/", "https://user:secret@instagram.com/share/reel/123/", "https://tiktok.com/share/video/not-a-number"] {
            XCTAssertNil(CodeGramSocialVideoLink.url(in: input), input)
        }
    }
    func testVideoFailuresIdentifyTheStageWithoutLeakingExtractorOutput() {
        let expectedHints = [
            "video_source_unavailable": "IP VPS",
            "video_login_required": "входа",
            "video_rate_limited": "ограничил",
            "video_network_error": "подключиться",
            "video_timeout": "время",
            "video_too_large": "250 МБ",
            "video_unsupported_codec": "H.264",
            "video_processing_failed": "ffmpeg",
            "video_dependency_missing": "компонентов",
            "insufficient_storage": "места",
            "video_unavailable": "получить или подготовить"
        ]
        for (code, hint) in expectedHints {
            XCTAssertTrue(CodeGramVPSError.socialVideoFailure(code: code).message.contains(hint), code)
            XCTAssertEqual(CodeGramVPSError.response(statusCode: 422, serverCode: code).message, CodeGramVPSError.socialVideoFailure(code: code).message)
        }
        let privateDiagnostic = "https://private.example/secret?token=secret"
        XCTAssertEqual(CodeGramVPSError.socialVideoFailure(code: privateDiagnostic).message, CodeGramVPSError.socialVideoFailure(code: nil).message)
        XCTAssertEqual(CodeGramVPSError.response(statusCode: 500, serverCode: privateDiagnostic).message, "Ошибка VPS (HTTP 500).")
        XCTAssertTrue(CodeGramVPSError.response(statusCode: 401, serverCode: "video_timeout").message.contains("ключ"))
        XCTAssertTrue(CodeGramVPSError.response(statusCode: 403, serverCode: "video_timeout").message.contains("другой Telegram-аккаунт"))
    }
    func testVPSConnectionErrorsDistinguishPhoneDownloadFromServerPreparation() {
        let error = URLError(.timedOut)
        XCTAssertTrue(CodeGramVPSError.connection(error).message.contains("не ответил"))
        XCTAssertTrue(CodeGramVPSError.connection(error, downloading: true).message.contains("на iPhone"))
        XCTAssertTrue(CodeGramVPSError.connection(URLError(.notConnectedToInternet)).message.contains("интернету"))
        XCTAssertTrue(CodeGramVPSError.connection(URLError(.cancelled)).message.contains("отменён"))
    }
    func testVideoDiagnosticReportsVersionAndWorkerWithoutShowingRawOutput() {
        let message = CodeGramVPSError.socialVideoFailure(code: "video_dns_error", serviceVersion: "5.2.0", stage: "resolve", workerExitCode: 1, exceptionType: "TransportError").message
        for expected in ["DNS", "video_dns_error", "VPS: 5.2.0", "Этап: ссылка и DNS", "Процесс: 1", "TransportError"] {
            XCTAssertTrue(message.contains(expected), expected)
        }
        for code in ["video_worker_failed", "video_worker_killed", "video_invalid_result", "video_unsupported_link", "video_extraction_failed"] {
            XCTAssertTrue(CodeGramVPSError.socialVideoFailure(code: code, serviceVersion: "5.2.0").message.contains("Код: \(code)"))
        }
        let privateValue = "https://private.example/?token=secret"
        let unknown = CodeGramVPSError.socialVideoFailure(code: privateValue, serviceVersion: privateValue, workerExitCode: 100000, exceptionType: privateValue).message
        XCTAssertFalse(unknown.contains(privateValue))
        XCTAssertFalse(unknown.contains("100000"))
        XCTAssertTrue(unknown.contains("версия не передана"))
        XCTAssertFalse(CodeGramVPSError.socialVideoFailure(code: "video_dns_error", serviceVersion: "5.2.0\nsecret").message.contains("secret"))
        XCTAssertTrue(CodeGramVPSError.connection(URLError(.dnsLookupFailed)).message.contains("адрес VPS"))
    }
    func testCancelledVideoIntentCannotEnqueueLateCompletion() {
        let url = URL(string: "https://www.tiktok.com/@owner/video/123")!
        var intent = CodeGramSocialVideoSendState(accountSession: "account-session", destination: "peer:thread", sourceURL: url)
        XCTAssertTrue(intent.cancel())
        XCTAssertFalse(intent.claimHandoff(attempt: 0, accountSession: "account-session"))
        XCTAssertEqual(intent.phase, .cancelled)
    }
    func testRetryRejectsOldCompletionAndHandoffIsExactlyOnce() {
        let url = URL(string: "https://www.instagram.com/reel/Ab123/")!
        var intent = CodeGramSocialVideoSendState(accountSession: "one", destination: "captured-peer:12", sourceURL: url)
        XCTAssertTrue(intent.fail(attempt: 0))
        XCTAssertEqual(intent.retry(), 1)
        XCTAssertFalse(intent.claimHandoff(attempt: 0, accountSession: "one"))
        XCTAssertFalse(intent.claimHandoff(attempt: 1, accountSession: "another-login"))
        XCTAssertTrue(intent.claimHandoff(attempt: 1, accountSession: "one"))
        XCTAssertFalse(intent.claimHandoff(attempt: 1, accountSession: "one"))
        XCTAssertFalse(intent.cancel()) // Already in the native pending-message handoff.
        XCTAssertTrue(intent.finishHandoff(attempt: 1, accepted: true))
        XCTAssertFalse(intent.finishHandoff(attempt: 1, accepted: true))
        XCTAssertEqual(intent.destination, "captured-peer:12")
        XCTAssertEqual(intent.sourceURL, url)
        XCTAssertNil(intent.retry())
    }
    func testTwoExplicitSendsOfTheSameLinkRemainIndependent() {
        let url = URL(string: "https://vt.tiktok.com/Ab123/")!
        var first = CodeGramSocialVideoSendState(accountSession: "one", destination: "peer-a", sourceURL: url)
        var second = CodeGramSocialVideoSendState(accountSession: "one", destination: "peer-b", sourceURL: url)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.cancel())
        XCTAssertTrue(second.claimHandoff(attempt: 0, accountSession: "one"))
        XCTAssertEqual(first.destination, "peer-a")
        XCTAssertEqual(second.destination, "peer-b")
    }
    func testVideoCacheOwnsMasterSeparatelyFromEachUploaderInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-cache-test-\(UUID().uuidString)")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-cache-source-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        try Data(repeating: 42, count: 1024).write(to: source)
        let url = URL(string: "https://www.instagram.com/reel/Ab123/")!
        let metadata = CodeGramSocialVideoFileCache.Metadata(sourceURL: url.absoluteString, size: 1024, duration: 2, width: 64, height: 64)
        let cache = CodeGramSocialVideoFileCache(directory: directory)
        let stored = expectation(description: "master stored")
        cache.store(source: source, metadata: metadata) { success in XCTAssertTrue(success); stored.fulfill() }
        wait(for: [stored], timeout: 5)
        try FileManager.default.removeItem(at: source)
        let copied = expectation(description: "independent uploader input")
        cache.copyForSend(sourceURL: url) { result in
            XCTAssertEqual(result?.0, metadata)
            if let input = result?.1 {
                XCTAssertEqual(try? Data(contentsOf: input).count, 1024)
                try? FileManager.default.removeItem(at: input) // Native uploader unlinks its own input.
            } else { XCTFail("Missing cached video") }
            copied.fulfill()
        }
        wait(for: [copied], timeout: 5)
        let again = expectation(description: "master survives uploader")
        cache.copyForSend(sourceURL: url) { result in
            XCTAssertNotNil(result)
            if let input = result?.1 { try? FileManager.default.removeItem(at: input) }
            again.fulfill()
        }
        wait(for: [again], timeout: 5)
        cache.invalidate()
        let loggedOut = expectation(description: "logout cannot reuse account cache")
        cache.copyForSend(sourceURL: url) { result in XCTAssertNil(result); loggedOut.fulfill() }
        wait(for: [loggedOut], timeout: 5)
    }
    func testVideoCacheExpiresAndRejectsUnvalidatedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodeGram-cache-expiry-\(UUID().uuidString)")
        let source = directory.appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source) }
        try Data(repeating: 1, count: 16).write(to: source)
        let url = URL(string: "https://vt.tiktok.com/Ab123/")!
        let metadata = CodeGramSocialVideoFileCache.Metadata(sourceURL: url.absoluteString, size: 16, duration: 1, width: 32, height: 32)
        let old = CodeGramSocialVideoFileCache(directory: directory, now: { Date(timeIntervalSince1970: 100) })
        let stored = expectation(description: "old master")
        old.store(source: source, metadata: metadata) { success in XCTAssertTrue(success); stored.fulfill() }
        wait(for: [stored], timeout: 5)
        let reopened = CodeGramSocialVideoFileCache(directory: directory, ttl: 60, now: { Date(timeIntervalSince1970: 161) })
        let expired = expectation(description: "expired input never used")
        reopened.copyForSend(sourceURL: url) { result in XCTAssertNil(result); expired.fulfill() }
        wait(for: [expired], timeout: 5)
        let invalid = CodeGramSocialVideoFileCache.Metadata(sourceURL: "https://private.example/video", size: 16, duration: .nan, width: 0, height: 32)
        let rejected = expectation(description: "invalid metadata")
        reopened.store(source: source, metadata: invalid) { success in XCTAssertFalse(success); rejected.fulfill() }
        wait(for: [rejected], timeout: 5)
    }

    func testCancelledCopyCanRetryWhileAnotherSameLinkSendKeepsPreparationAlive() {
        let url = URL(string: "https://vt.tiktok.com/Ab123/")!
        var first = CodeGramSocialVideoSendState(accountSession: "one", destination: "peer-a", sourceURL: url)
        let second = CodeGramSocialVideoSendState(accountSession: "one", destination: "peer-b", sourceURL: url)
        var copies = CodeGramSocialVideoCopyClaims()
        XCTAssertTrue(copies.claim(id: first.id, attempt: 0))
        XCTAssertTrue(copies.claim(id: second.id, attempt: 0))
        XCTAssertTrue(first.cancel())
        XCTAssertEqual(first.retry(), 1)
        XCTAssertTrue(copies.claim(id: first.id, attempt: 1))
        XCTAssertFalse(copies.release(id: first.id, attempt: 0)) // Late cancelled copy cannot clear its retry.
        XCTAssertFalse(copies.claim(id: first.id, attempt: 1)) // One clone per current attempt.
        XCTAssertFalse(first.claimHandoff(attempt: 0, accountSession: "one"))
        XCTAssertTrue(copies.release(id: first.id, attempt: 1))
        XCTAssertTrue(first.claimHandoff(attempt: 1, accountSession: "one"))
        XCTAssertTrue(copies.release(id: second.id, attempt: 0))
    }

}

