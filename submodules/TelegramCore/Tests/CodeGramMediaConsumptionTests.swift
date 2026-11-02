import XCTest
@testable import TelegramCore

final class CodeGramMediaConsumptionTests: XCTestCase {
    func testOpeningOnlyHoldsUnopenedIncomingDisappearingMedia() {
        XCTAssertTrue(CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: true,
            isDisappearingMedia: true, isConsumed: false, countdownStarted: false, force: false))
        XCTAssertFalse(CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: true,
            isDisappearingMedia: true, isConsumed: false, countdownStarted: false, force: true))
        XCTAssertFalse(CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: true,
            isDisappearingMedia: true, isConsumed: false, countdownStarted: true, force: false))
        XCTAssertFalse(CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: true,
            isDisappearingMedia: false, isConsumed: false, countdownStarted: false, force: false))
        XCTAssertFalse(CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: false,
            isDisappearingMedia: true, isConsumed: false, countdownStarted: false, force: false))
    }

    func testOptionalArchiveWaitsForNativeCatchupAndPreservesCooldown() {
        let policy = CodeGramEnergyPolicy(lowPower: false, thermalLevel: 0)
        XCTAssertNil(policy.syncResumeDelay(inForeground: true, isUpdatingMessages: true, notBefore: 0, now: 100))
        XCTAssertNil(policy.syncResumeDelay(inForeground: false, isUpdatingMessages: false, notBefore: 0, now: 100))
        XCTAssertEqual(policy.syncResumeDelay(inForeground: true, isUpdatingMessages: false, notBefore: 400, now: 100), 300)
        XCTAssertEqual(policy.syncResumeDelay(inForeground: true, isUpdatingMessages: false, notBefore: 0, now: 100), 8)
    }
}
