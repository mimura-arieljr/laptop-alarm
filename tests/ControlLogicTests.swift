import Foundation

func runControlLogicTests() {
    testStatusRepliesWithState()
    testCancelOnlyBeforeArmed()
    testDisarmOnlyWhenArmedLike()
    testDisarmRateLimited()
    testPasswordResultUpdatesLimiter()
    testStateText()
    testErrorText()
    testConnectErrorText()
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

func testStatusRepliesWithState() {
    let states: [AlarmState] = [.countdown(4), .calibrating, .armed, .degraded("x"), .triggered("y")]
    for s in states {
        expect(decideControl(.status, state: s, limiter: AttemptLimiter(), now: t0) == .reply(.state(s)),
            "STATUS replies with \(s)")
    }
}

func testCancelOnlyBeforeArmed() {
    for s in [AlarmState.countdown(3), .calibrating] {
        expect(decideControl(.cancel, state: s, limiter: AttemptLimiter(), now: t0) == .cancel,
            "CANCEL accepted in \(s)")
    }
    for s in [AlarmState.armed, .degraded("x"), .triggered("y"), .disarmed] {
        expect(decideControl(.cancel, state: s, limiter: AttemptLimiter(), now: t0) == .reply(.error("not-cancellable")),
            "CANCEL refused in \(s)")
    }
}

func testDisarmOnlyWhenArmedLike() {
    let cmd = ClientCommand.disarm(password: "pw")
    for s in [AlarmState.armed, .degraded("x"), .triggered("y")] {
        expect(decideControl(cmd, state: s, limiter: AttemptLimiter(), now: t0) == .verify(password: "pw"),
            "DISARM verifies in \(s)")
    }
    for s in [AlarmState.countdown(3), .calibrating, .disarmed] {
        expect(decideControl(cmd, state: s, limiter: AttemptLimiter(), now: t0) == .reply(.error("not-armed")),
            "DISARM refused in \(s)")
    }
}

func testDisarmRateLimited() {
    var l = AttemptLimiter()
    l.recordFailure(at: t0)
    let cmd = ClientCommand.disarm(password: "pw")
    expect(decideControl(cmd, state: .armed, limiter: l, now: t0.addingTimeInterval(0.5)) == .reply(.error("rate-limited")),
        "blocked limiter refuses DISARM")
    expect(decideControl(cmd, state: .armed, limiter: l, now: t0.addingTimeInterval(1.1)) == .verify(password: "pw"),
        "released limiter allows DISARM")
    expect(decideControl(cmd, state: .countdown(3), limiter: l, now: t0.addingTimeInterval(0.5)) == .reply(.error("not-armed")),
        "state check wins over rate limit")
}

func testPasswordResultUpdatesLimiter() {
    var l = AttemptLimiter()
    expect(passwordResult(ok: false, limiter: &l, now: t0) == .error("wrong-password"), "wrong password reply")
    expect(l.isBlocked(at: t0.addingTimeInterval(0.5)), "failure blocks")
    expect(passwordResult(ok: true, limiter: &l, now: t0.addingTimeInterval(2)) == .ok, "right password reply")
    expect(!l.isBlocked(at: t0.addingTimeInterval(2)), "success resets")
}

func testStateText() {
    expect(describe(.disarmed) == "Disarmed", "disarmed text")
    expect(describe(.countdown(7)) == "Arming in 7 s", "countdown text")
    expect(describe(.calibrating) == "Calibrating", "calibrating text")
    expect(describe(.armed) == "Armed", "armed text")
    expect(describe(.degraded("Sensor out")) == "Armed (degraded): Sensor out", "degraded text")
    expect(describe(.triggered("lid closed")) == "ALARM TRIGGERED: lid closed", "triggered text")
}

func testErrorText() {
    expect(disarmErrorText("wrong-password") == "Wrong password.", "wrong-password text")
    expect(disarmErrorText("rate-limited") == "Too many wrong passwords. Wait and try again.", "rate-limited text")
    expect(disarmErrorText("not-armed") == "The alarm is not armed.", "not-armed text")
    expect(disarmErrorText("weird") == "Engine error: weird", "unknown error text")
}

func testConnectErrorText() {
    expect(connectErrorText(ENOENT) == "No alarm is running.", "missing socket")
    expect(connectErrorText(ECONNREFUSED) == "No alarm is running.", "refused socket")
    expect(connectErrorText(EACCES).hasPrefix("Cannot reach the alarm"), "permission error mentions the alarm")
}
