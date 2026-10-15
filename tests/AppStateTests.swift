import Foundation

func runAppStateTests() {
    testReduceHappyPath()
    testCancelledDialogReturnsToDisarmed()
    testLostConnectionWhileArmedIsLost()
    testCancelFlowEndsDisarmed()
    testDegradedState()
    testIgnoredEvents()
    testPresentation()
    testQuitEnabledMatrix()
}

private func run(_ start: AppState, _ events: [AppEvent]) -> AppState {
    events.reduce(start) { reduce($0, $1) }
}

func testReduceHappyPath() {
    expect(reduce(.disarmed, .armTapped) == .launching, "arm tapped launches")
    expect(reduce(.launching, .elevation(.started)) == .launching, "started stays launching")
    expect(reduce(.launching, .engine(.state(.countdown(7)))) == .countdown(7), "countdown")
    expect(reduce(.countdown(7), .engine(.state(.calibrating))) == .calibrating, "calibrating")
    expect(reduce(.calibrating, .engine(.state(.armed))) == .armed, "armed")
    expect(reduce(.armed, .engine(.state(.triggered("lid closed")))) == .triggered("lid closed"), "triggered")
    expect(reduce(.triggered("lid closed"), .engine(.state(.disarmed))) == .disarmed, "disarmed")
}

func testCancelledDialogReturnsToDisarmed() {
    expect(reduce(.launching, .elevation(.cancelled)) == .disarmed, "cancelled dialog")
    expect(reduce(.launching, .elevation(.failed("x"))) == .failed("x"), "failed elevation")
    expect(
        reduce(.launching, .connectTimedOut) == .failed("The alarm engine did not start."),
        "connect timeout")
    expect(reduce(.failed("x"), .armTapped) == .launching, "retry from failed")
}

func testLostConnectionWhileArmedIsLost() {
    for s in [AppState.armed, .armedDegraded("r"), .triggered("t")] {
        expect(reduce(s, .connectionClosed) == .lost, "connection closed while \(s) is lost")
    }
    for s in [AppState.launching, .countdown(3), .calibrating] {
        expect(
            reduce(s, .connectionClosed) == .failed("The alarm engine stopped before arming."),
            "connection closed while \(s) is a failure")
    }
    expect(reduce(.lost, .connectionClosed) == .lost, "lost stays lost")
    expect(reduce(.failed("x"), .connectionClosed) == .failed("x"), "failed stays failed")
    expect(reduce(.disarmed, .engine(.state(.armed))) == .armed, "relaunch into running engine")
}

func testCancelFlowEndsDisarmed() {
    let end = run(.countdown(5), [.engine(.state(.disarmed)), .connectionClosed])
    expect(end == .disarmed, "cancel (STATE disarmed then close) ends disarmed, not failed")
}

func testDegradedState() {
    expect(reduce(.armed, .engine(.state(.degraded("r")))) == .armedDegraded("r"), "degraded")
}

func testIgnoredEvents() {
    let busy: [AppState] = [
        .launching, .countdown(5), .calibrating, .armed, .armedDegraded("r"), .triggered("t"), .lost,
    ]
    for s in busy {
        expect(reduce(s, .armTapped) == s, "arm tapped ignored in \(s)")
        expect(reduce(s, .engine(.warning("w"))) == s, "warning ignored in \(s)")
        expect(reduce(s, .engine(.ok)) == s, "ok ignored in \(s)")
        expect(reduce(s, .engine(.error("e"))) == s, "error ignored in \(s)")
    }
    expect(reduce(.armed, .connectTimedOut) == .armed, "timeout only matters while launching")
    expect(reduce(.armed, .elevation(.cancelled)) == .armed, "late elevation result ignored")
    expect(reduce(.disarmed, .connectionClosed) == .disarmed, "closed while disarmed")
}

func testPresentation() {
    let d = presentation(for: .disarmed)
    expect(d.statusText == "Disarmed", "disarmed text")
    expect(d.armEnabled && d.quitEnabled && d.tint == .none, "disarmed flags")
    expect(!d.cancelVisible && !d.disarmVisible && !d.flashing, "disarmed hides actions")

    let c = presentation(for: .countdown(7))
    expect(c.statusText == "Arming in 7 s", "countdown text")
    expect(c.cancelVisible && !c.quitEnabled && !c.armEnabled, "countdown flags")

    let cal = presentation(for: .calibrating)
    expect(cal.cancelVisible && !cal.quitEnabled && !cal.armEnabled, "calibrating shows cancel")

    let a = presentation(for: .armed)
    expect(a.tint == .red && a.disarmVisible && !a.quitEnabled, "armed flags")

    let g = presentation(for: .armedDegraded("accelerometer stale"))
    expect(g.tint == .orange && g.statusText.contains("accelerometer stale"), "degraded flags")
    expect(g.disarmVisible, "degraded can be disarmed")

    let t = presentation(for: .triggered("lid closed"))
    expect(t.statusText == "ALARM: lid closed", "triggered text")
    expect(t.tint == .red && t.flashing && t.disarmVisible, "triggered flags")

    let l = presentation(for: .lost)
    expect(l.statusText.contains("sudo pmset -a disablesleep 0"), "lost text has recovery command")
    expect(l.quitEnabled, "lost can quit")
    expect(l.statusText.contains("Quit and reopen the app to reconnect."), "lost text says how to reconnect")
    expect(!l.armEnabled, "lost cannot arm")

    let f = presentation(for: .failed("boom"))
    expect(f.statusText.contains("boom") && f.armEnabled && f.quitEnabled, "failed flags")
}

func testQuitEnabledMatrix() {
    let blocked: [AppState] = [
        .launching, .countdown(1), .calibrating, .armed, .armedDegraded("r"), .triggered("t"),
    ]
    for s in blocked { expect(!presentation(for: s).quitEnabled, "quit disabled in \(s)") }
    for s in [AppState.disarmed, .failed("x"), .lost] {
        expect(presentation(for: s).quitEnabled, "quit enabled in \(s)")
    }
}
