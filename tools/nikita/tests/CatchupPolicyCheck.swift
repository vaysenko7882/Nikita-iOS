import Foundation

@main enum CatchupPolicyCheck {
    static func main() {
        var scenarios = 0
        for incoming in [false, true] {
            for disappearing in [false, true] {
                for consumed in [false, true] {
                    for started in [false, true] {
                        for force in [false, true] {
                            let held = CodeGramMediaConsumptionPolicy.defersConsumption(isIncoming: incoming,
                                isDisappearingMedia: disappearing, isConsumed: consumed, countdownStarted: started, force: force)
                            precondition(held == (incoming && disappearing && !consumed && !started && !force))
                            scenarios += 1
                        }
                    }
                }
            }
        }
        let cache = CodeGramArchiveTokenCache()
        var reads = 0
        for _ in 0 ..< 10_000 {
            precondition(cache.token(account: "one", load: { reads += 1; return "first" }) == "first")
        }
        precondition(reads == 1)
        precondition(cache.token(account: "two", load: { return nil }) == "")
        precondition(cache.token(account: "two", load: { return "unlocked" }) == "unlocked")
        precondition(!cache.store(account: "one", token: "bad", write: { false }))
        precondition(cache.token(account: "one", load: { fatalError("Lost successful cache") }) == "first")
        precondition(cache.store(account: "one", token: "replacement", write: { true }))
        precondition(cache.token(account: "one", load: { fatalError("Unnecessary Keychain read") }) == "replacement")
        let concurrent = CodeGramArchiveTokenCache()
        var concurrentReads = 0
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            precondition(concurrent.token(account: "shared", load: { concurrentReads += 1; return "value" }) == "value")
        }
        precondition(concurrentReads == 1)
        var missingReads = 0
        for _ in 0 ..< 100 {
            precondition(cache.token(account: "absent", load: { missingReads += 1; return "" }) == "")
        }
        precondition(missingReads == 1)
        print("Media consumption: \(scenarios) incoming/outgoing, ordinary/disappearing, consumed/countdown and manual-force scenarios passed.")
        print("Keychain cache: 10,000 sequential and 1,000 concurrent lookups each perform one read; unlock retry, missing item, account isolation and failed/successful writes passed.")
    }
}
