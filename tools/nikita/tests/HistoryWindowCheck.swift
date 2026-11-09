import Foundation

private struct HistoryWork {
    var requestedWindows: [Int]
    var visitedMessages: Int
    var retainedMessages: Int
    var visibleMessages: Int
}

// This models the message traversal of a loaded tail/centered history window;
// the window selection below calls the production policy directly. The timing
// is a host policy/filter workload, not an iPhone rendering or thermal result.
@inline(never) private func historyWork(hiddenAuthors: [Bool], filterActive: Bool, centered: Bool = false, legacy: Bool) -> HistoryWork {
    var count = legacy && filterActive ? 512 : MessageFilterHistoryWindow.initialMessageCount
    var result = HistoryWork(requestedWindows: [], visitedMessages: 0, retainedMessages: 0, visibleMessages: 0)
    while true {
        let loadedCount = min(hiddenAuthors.count, centered ? count * 2 : count)
        var hiddenCount = 0
        for index in 0 ..< loadedCount {
            if filterActive && hiddenAuthors[index] {
                hiddenCount += 1
            }
        }
        result.requestedWindows.append(count)
        result.visitedMessages += loadedCount
        result.retainedMessages = loadedCount
        result.visibleMessages = loadedCount - hiddenCount
        guard !legacy, filterActive, let expandedCount = MessageFilterHistoryWindow.expandedMessageCount(
            currentCount: count,
            loadedMessageCount: loadedCount,
            hiddenMessageCount: hiddenCount,
            hasMoreMessages: loadedCount < hiddenAuthors.count
        ) else {
            return result
        }
        precondition(expandedCount > count && expandedCount <= MessageFilterHistoryWindow.maximumMessageCount)
        count = expandedCount
    }
}

@main enum HistoryWindowCheck {
    static func main() throws {
        let noHidden = Array(repeating: false, count: 2_000)
        var sparse = noHidden
        sparse[0] = true
        let halfHidden = (0 ..< 2_000).map { $0 % 2 == 0 }
        let allHidden = Array(repeating: true, count: 2_000)
        let prefixHidden = Array(repeating: true, count: 100) + noHidden
        let cases: [(String, [Bool], Bool, Bool)] = [
            ("inactive_filter", noHidden, false, false),
            ("active_filter_other_chat", noHidden, true, false),
            ("active_filter_other_chat_centered", noHidden, true, true),
            ("one_hidden_message", sparse, true, false),
            ("half_hidden_messages", halfHidden, true, false),
            ("all_hidden_messages", allHidden, true, false),
            ("hidden_prefix", prefixHidden, true, false),
            ("exhausted_hidden_history", Array(repeating: true, count: 20), true, false)
        ]
        var scenarios: [[String: Any]] = []
        for (name, authors, active, centered) in cases {
            let before = historyWork(hiddenAuthors: authors, filterActive: active, centered: centered, legacy: true)
            let after = historyWork(hiddenAuthors: authors, filterActive: active, centered: centered, legacy: false)
            scenarios.append([
                "name": name,
                "before_requested_windows": before.requestedWindows,
                "after_requested_windows": after.requestedWindows,
                "before_visited_messages": before.visitedMessages,
                "after_visited_messages": after.visitedMessages,
                "after_retained_messages": after.retainedMessages,
                "after_visible_messages": after.visibleMessages
            ])
            switch name {
            case "inactive_filter", "active_filter_other_chat", "active_filter_other_chat_centered", "exhausted_hidden_history":
                precondition(after.requestedWindows == [44])
            case "one_hidden_message":
                precondition(after.requestedWindows == [44, 46] && after.visibleMessages >= 44)
            case "half_hidden_messages":
                precondition(after.requestedWindows == [44, 88] && after.visibleMessages == 44)
            case "all_hidden_messages":
                precondition(after.requestedWindows == [44, 512] && after.visibleMessages == 0)
            case "hidden_prefix":
                precondition(after.requestedWindows == [44, 512] && after.visibleMessages >= 44)
            default:
                preconditionFailure("Unchecked scenario")
            }
        }

        let iterations = 20_000
        var timings: [String: Any] = ["iterations": iterations]
        for legacy in [true, false] {
            let start = Date.timeIntervalSinceReferenceDate
            var checksum = 0
            for _ in 0 ..< iterations {
                let work = historyWork(hiddenAuthors: noHidden, filterActive: true, legacy: legacy)
                checksum += work.visitedMessages
            }
            precondition(checksum == iterations * (legacy ? 512 : 44))
            timings[legacy ? "before_ms" : "after_ms"] = (Date.timeIntervalSinceReferenceDate - start) * 1_000.0
            timings[legacy ? "before_visited_messages" : "after_visited_messages"] = checksum
        }
        let report: [String: Any] = [
            "scope": "production history window policy with simulated loaded-message filtering; not device rendering or thermal measurement",
            "scenarios": scenarios,
            "active_filter_other_chat_host_workload": timings
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
