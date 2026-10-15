import Foundation

/// Exponential backoff for password attempts.
/// - After the nth consecutive failure, blocked for min(2^(n-1), 30) seconds.
struct AttemptLimiter {
    private var failures = 0
    private var blockedUntil = Date.distantPast

    mutating func recordFailure(at now: Date) {
        failures += 1
        let delay = min(pow(2.0, Double(min(failures, 10) - 1)), 30)
        blockedUntil = now.addingTimeInterval(delay)
    }

    mutating func recordSuccess() {
        failures = 0
        blockedUntil = .distantPast
    }

    func isBlocked(at now: Date) -> Bool {
        now < blockedUntil
    }
}
