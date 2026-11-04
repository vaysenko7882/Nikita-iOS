import Foundation

/// One explicit Send intent. Recipient and session do not follow the visible chat.
public struct CodeGramSocialVideoSendState {
    public enum Phase: Equatable { case preparing, enqueueing, enqueued, failed, cancelled }
    public let id: UUID
    public let accountSession: String
    public let destination: String
    public let sourceURL: URL
    public private(set) var phase: Phase = .preparing
    public private(set) var attempt: Int = 0
    public init(id: UUID = UUID(), accountSession: String, destination: String, sourceURL: URL) {
        self.id = id; self.accountSession = accountSession; self.destination = destination; self.sourceURL = sourceURL
    }
    public mutating func retry() -> Int? {
        guard self.phase == .failed || self.phase == .cancelled else { return nil }
        self.attempt += 1; self.phase = .preparing
        return self.attempt
    }
    public mutating func claimHandoff(attempt: Int, accountSession: String) -> Bool {
        guard self.phase == .preparing, self.attempt == attempt, self.accountSession == accountSession else { return false }
        self.phase = .enqueueing
        return true
    }
    @discardableResult public mutating func finishHandoff(attempt: Int, accepted: Bool) -> Bool {
        guard self.phase == .enqueueing, self.attempt == attempt else { return false }
        self.phase = accepted ? .enqueued : .failed
        return true
    }
    @discardableResult public mutating func fail(attempt: Int) -> Bool {
        guard self.phase == .preparing, self.attempt == attempt else { return false }
        self.phase = .failed
        return true
    }
    @discardableResult public mutating func cancel() -> Bool {
        guard self.phase == .preparing || self.phase == .failed else { return false }
        self.phase = .cancelled
        return true
    }
}
