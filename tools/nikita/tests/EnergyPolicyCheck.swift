import Foundation

@main struct EnergyPolicyCheck {
    static func main() {
        for thermal in 0 ... 3 {
            for lowPower in [false, true] {
                let policy = CodeGramEnergyPolicy(lowPower: lowPower, thermalLevel: thermal)
                precondition(policy.allowsAutomaticSync == (thermal < 2))
                precondition(policy.pageBudget == (lowPower || thermal > 0 ? 1 : 4))
                precondition(policy.backgroundDuration <= 60)
                if thermal >= 2 { precondition(policy.backgroundDuration == 0) }
                else if lowPower || thermal > 0 { precondition(policy.backgroundDuration == 15) }
                var previous = 0.0
                for idle in 0 ... 20 {
                    let delay = policy.syncDelay(idleCount: idle, failureCount: 0)
                    precondition(delay >= previous && delay <= 600)
                    previous = delay
                }
                previous = 0
                for failures in 1 ... 20 {
                    let delay = policy.syncDelay(idleCount: 0, failureCount: failures)
                    precondition(delay >= previous && delay <= 900)
                    previous = delay
                }
                // Activity clears idle/error backoff without changing preferences.
                precondition(policy.syncDelay(idleCount: 0, failureCount: 0) == (policy.usesReducedEffects ? 120 : 30))
            }
        }
        print("Energy policy: all thermal/power states, bounded catch-up, idle backoff, failure backoff and activity recovery passed.")
    }
}
