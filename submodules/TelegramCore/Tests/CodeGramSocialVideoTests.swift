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
}

