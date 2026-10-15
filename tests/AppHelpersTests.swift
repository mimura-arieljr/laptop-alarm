import Foundation

func runAppHelpersTests() {
    testChooseEnginePath()
    testStaleVoiceDirectories()
    testWarningList()
    testWrapText()
}

func testChooseEnginePath() {
    let both: (String) -> Bool = { _ in true }
    expect(chooseEnginePath(resourceDir: "/A/Res", executableDir: "/A/bin", exists: both) == "/A/Res/laptop-alarm", "bundle engine wins")
    let onlyExe: (String) -> Bool = { $0 == "/A/bin/laptop-alarm" }
    expect(chooseEnginePath(resourceDir: "/A/Res", executableDir: "/A/bin", exists: onlyExe) == "/A/bin/laptop-alarm", "falls back to executable dir")
    expect(chooseEnginePath(resourceDir: nil, executableDir: "/A/bin", exists: onlyExe) == "/A/bin/laptop-alarm", "no resource dir")
    expect(chooseEnginePath(resourceDir: "/A/Res", executableDir: "/A/bin", exists: { _ in false }) == nil, "no engine anywhere")
}

func testStaleVoiceDirectories() {
    let names = ["laptop-alarm-voice-1", "laptop-alarm-voice-2", "other", "laptop-alarm-test-x.wav"]
    expect(staleVoiceDirectories(in: names) == ["laptop-alarm-voice-1", "laptop-alarm-voice-2"], "selects only voice dirs")
    expect(staleVoiceDirectories(in: names, keeping: "laptop-alarm-voice-2") == ["laptop-alarm-voice-1"], "keeps the live dir")
    expect(staleVoiceDirectories(in: []).isEmpty, "empty listing")
}

func testWarningList() {
    var w = WarningList()
    w.add("a")
    w.add("b")
    w.add("a")
    expect(w.items == ["a", "b"], "de-duplicates and keeps order")
    w.clear()
    expect(w.items.isEmpty, "clear empties")
    w.add("a")
    expect(w.items == ["a"], "usable after clear")
}

func testWrapText() {
    expect(wrapText("one two three", width: 7) == ["one two", "three"], "wraps at width")
    expect(wrapText("", width: 10).isEmpty, "empty text")
    expect(wrapText("abcdefghij k", width: 5) == ["abcdefghij", "k"], "long word kept whole")
    let lost = presentation(for: .lost).statusText
    let lines = statusDisplayLines(lost, width: 44)
    expect(lines.joined(separator: " ") == lost, "wrapping loses no text")
    expect(lines.contains("sudo pmset -a disablesleep 0"), "recovery command is its own line")
    expect(lines.allSatisfy { $0.count <= 44 }, "lines fit the width")
    expect(statusDisplayLines("Armed", width: 44) == ["Armed"], "short text unchanged")
}
