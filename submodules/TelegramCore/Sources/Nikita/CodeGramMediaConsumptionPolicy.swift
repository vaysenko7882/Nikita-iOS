import Foundation

/// Reading a chat is unchanged. Only an unopened disappearing attachment waits
/// for an explicit action; an existing countdown is never paused or reset.
public enum CodeGramMediaConsumptionPolicy {
    public static func defersConsumption(isIncoming: Bool, isDisappearingMedia: Bool,
        isConsumed: Bool, countdownStarted: Bool, force: Bool) -> Bool {
        return isIncoming && isDisappearingMedia && !isConsumed && !countdownStarted && !force
    }
}
