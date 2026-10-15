import Foundation

func runSettingsTests() {
    testDefaultEngineArguments()
    testPresetValues()
}

func testDefaultEngineArguments() {
    let want = [
        "arm", "--headless", "--user", "alice", "--countdown", "10",
        "--tilt", "2.0", "--shock", "0.09", "--volume", "1.0",
    ]
    expect(AppSettings().engineArguments(user: "alice") == want, "default engine arguments")
    let low = AppSettings(sensitivity: .low, siren: .low).engineArguments(user: "bob")
    let wantLow = [
        "arm", "--headless", "--user", "bob", "--countdown", "10",
        "--tilt", "5.0", "--shock", "0.15", "--volume", "0.25",
    ]
    expect(low == wantLow, "low/low engine arguments, got \(low)")
}

func testPresetValues() {
    expect(Sensitivity.high.tiltDegrees == 1.0 && Sensitivity.high.shockG == 0.06, "high sensitivity")
    expect(SirenLevel.medium.volume == 0.5, "medium siren")
    expect(Sensitivity.allCases.count == 3 && SirenLevel.allCases.count == 3, "three presets each")
    let s = AppSettings(sensitivity: .high, siren: .medium)
    let data = try? JSONEncoder().encode(s)
    let back = data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
    expect(back == s, "settings round trip through JSON")
}
