import Foundation

/// Only optional client work is throttled. Recording, calls and user downloads
/// retain their normal behavior; the VPS collector continues independently.
public struct CodeGramEnergyPolicy {
    public let lowPower: Bool
    public let thermalLevel: Int

    public init(lowPower: Bool, thermalLevel: Int) {
        self.lowPower = lowPower
        self.thermalLevel = thermalLevel
    }

    public static var current: CodeGramEnergyPolicy {
        return CodeGramEnergyPolicy(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
    }

    public var allowsAutomaticSync: Bool { return self.thermalLevel < 2 }
    public var usesReducedEffects: Bool { return self.lowPower || self.thermalLevel > 0 }
    public var pageBudget: Int { return self.usesReducedEffects ? 1 : 4 }
    public var backgroundDuration: Double {
        if self.thermalLevel >= 2 { return 0 }
        return self.usesReducedEffects ? 15 : 60
    }

    public var syncPageDelay: Double { return self.usesReducedEffects ? 3 : 1 }

    public func syncResumeDelay(inForeground: Bool, isUpdatingMessages: Bool, notBefore: Double, now: Double) -> Double? {
        guard inForeground, !isUpdatingMessages, self.allowsAutomaticSync else { return nil }
        return max(self.usesReducedEffects ? 15 : 8, notBefore - now)
    }

    public func syncDelay(idleCount: Int, failureCount: Int) -> Double {
        if failureCount > 0 { return min(900, 30 * pow(2, Double(min(5, failureCount)))) }
        let base: Double = self.usesReducedEffects ? 120 : 30
        return min(self.usesReducedEffects ? 600 : 300, base * pow(2, Double(min(4, max(0, idleCount)))))
    }
}
