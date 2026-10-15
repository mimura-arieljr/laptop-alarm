import Foundation

func runAttemptLimiterTests() {
    testLimiterBlocksThenReleases()
}

func testLimiterBlocksThenReleases() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var l = AttemptLimiter()
    expect(!l.isBlocked(at: t0), "fresh limiter is free")
    l.recordFailure(at: t0)
    expect(l.isBlocked(at: t0.addingTimeInterval(0.5)), "blocked 0.5 s after one failure")
    expect(!l.isBlocked(at: t0.addingTimeInterval(1.1)), "free 1.1 s after one failure")

    l.recordFailure(at: t0)
    l.recordFailure(at: t0)
    expect(l.isBlocked(at: t0.addingTimeInterval(3.9)), "blocked 3.9 s after three failures")
    expect(!l.isBlocked(at: t0.addingTimeInterval(4.1)), "free 4.1 s after three failures")

    for _ in 0..<7 { l.recordFailure(at: t0) }
    expect(l.isBlocked(at: t0.addingTimeInterval(29.9)), "blocked at 29.9 s after ten failures")
    expect(!l.isBlocked(at: t0.addingTimeInterval(30.1)), "capped at 30 s after ten failures")

    l.recordSuccess()
    expect(!l.isBlocked(at: t0), "success resets")
    l.recordFailure(at: t0)
    expect(!l.isBlocked(at: t0.addingTimeInterval(1.1)), "after reset, one failure is 1 s again")
}
