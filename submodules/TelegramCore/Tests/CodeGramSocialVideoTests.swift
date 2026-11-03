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
}
