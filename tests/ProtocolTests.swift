import Foundation

func runProtocolTests() {
    testStateLinesRoundTrip()
    testPasswordSurvivesWire()
    testGarbageDecodesToNil()
}

func testStateLinesRoundTrip() {
    let states: [AlarmState] = [
        .disarmed, .countdown(7), .calibrating, .armed,
        .degraded("accelerometer stale"), .triggered("tilt over 5 degrees"),
    ]
    for s in states {
        let line = encode(EngineMessage.state(s))
        expect(!line.contains("\n"), "state line has no newline: \(s)")
        expect(decodeEngineMessage(line) == .state(s), "state round trip: \(s), line \(line)")
    }
    for m in [EngineMessage.warning("low battery"), .ok, .error("bad_password")] {
        expect(decodeEngineMessage(encode(m)) == m, "message round trip: \(m)")
    }
    expect(encode(EngineMessage.state(.countdown(7))) == "STATE countdown 7", "countdown wire form")
    let multi = encode(EngineMessage.warning("a\nb"))
    expect(multi == "WARN a b", "newlines become spaces, got \(multi)")
}

func testPasswordSurvivesWire() {
    let passwords = [
        "p@ss \"w\" \\ 'x'\n日本 🔐",
        "\u{FEFF}abc",
        "e\u{301}",
        "\u{E9}",
    ]
    for pw in passwords {
        let line = encode(ClientCommand.disarm(password: pw))
        expect(!line.contains("\n"), "disarm line has no raw newline")
        if case .disarm(let got)? = decodeClientCommand(line) {
            expect(Array(got.utf8) == Array(pw.utf8), "password bytes identical for \(Array(pw.utf8))")
        } else {
            expect(false, "disarm decodes for \(Array(pw.utf8))")
        }
    }
    for c in [ClientCommand.status, .cancel] {
        expect(decodeClientCommand(encode(c)) == c, "command round trip: \(c)")
    }
    // Invalid UTF-8 inside valid base64 is rejected.
    let bad = "DISARM " + Data([0xFF, 0xFE, 0x41]).base64EncodedString()
    expect(decodeClientCommand(bad) == nil, "invalid UTF-8 password is nil")
}

func testGarbageDecodesToNil() {
    for g in ["", "HELLO", "DISARM !!!"] {
        expect(decodeClientCommand(g) == nil, "client garbage nil: '\(g)'")
        expect(decodeEngineMessage(g) == nil, "engine garbage nil: '\(g)'")
    }
}
