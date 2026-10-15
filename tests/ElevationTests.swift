import Foundation

func runElevationTests() {
    testInterpretOsascript()
    testShellQuote()
    testOsascriptArgumentsEscape()
    testOsascriptRoundTripsHostileInput()
}

/// Hostile strings: spaces, quotes, backslashes, expansions, separators, newlines.
private let hostile = [
    "/tmp/a b/it's",
    "plain",
    "",
    "a\"b",
    "a\\b",
    "a\\\"b",
    "$(echo pwned)",
    "`echo pwned`",
    "$HOME ${HOME}",
    "a; echo pwned",
    "a && echo pwned | cat > /tmp/x",
    "line1\nline2",
    "''''",
    "'; rm -rf / #",
    "*?[a-z]~",
    "tab\there",
    "日本 \u{1F512}",
    "-n",
    "!history #comment",
]

func testInterpretOsascript() {
    expect(interpretOsascript(status: 0, stderr: "") == .started, "status 0 is started")
    let cancel = "0:42: execution error: User canceled. (-128)\n"
    expect(interpretOsascript(status: 1, stderr: cancel) == .cancelled, "-128 is cancelled")
    expect(
        interpretOsascript(status: 1, stderr: "  some failure \n") == .failed("some failure"),
        "other stderr is failed and trimmed")
}

/// Runs `printf %s <quoted>` in /bin/sh and returns stdout, or nil on a launch failure.
private func shellEcho(_ quoted: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf %s " + quoted]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func testShellQuote() {
    for s in hostile {
        expect(shellEcho(shellQuote(s)) == s, "shell round trip for \(s.debugDescription)")
    }
    // Several quoted words stay separate words.
    let joined = hostile.map(shellQuote).joined(separator: " ")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "printf '%s\\0' " + joined]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let parts = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
    expect(Array(parts.dropLast()).map(String.init) == hostile, "joined words survive as separate argv")
}

func testOsascriptArgumentsEscape() {
    let args = osascriptArguments(enginePath: "/tmp/we\"ird\\path/engine", engineArguments: ["arm"])
    expect(args.count == 2 && args[0] == "-e", "osascript takes -e script")
    let script = args.last ?? ""
    expect(script.hasPrefix("do shell script \""), "script prefix")
    expect(script.hasSuffix(" > /dev/null 2>&1 &\" with administrator privileges"), "script suffix")
    expect(script.contains("we\\\"ird\\\\path"), "quote and backslash are escaped, got \(script)")
    expect(!script.contains("we\"ird"), "no raw quote from the path")
}

private func osascript(_ args: [String]) -> (status: Int32, stdout: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Evaluates the script's string literal without elevation and checks the shell command it carries.
func testOsascriptRoundTripsHostileInput() {
    let prefix = "do shell script "
    let suffix = " with administrator privileges"
    for path in hostile.filter({ !$0.isEmpty }) {
        let args = hostile + ["--user", path]
        let script = osascriptArguments(enginePath: "/tmp/" + path, engineArguments: args).last ?? ""
        guard script.hasPrefix(prefix), script.hasSuffix(suffix) else {
            expect(false, "script shape for \(path.debugDescription)")
            continue
        }
        let literal = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        let r = osascript(["-e", "return " + literal])
        let command = shellQuote("/tmp/" + path) + " " + args.map(shellQuote).joined(separator: " ")
            + " > /dev/null 2>&1 &"
        expect(r.status == 0, "AppleScript literal evaluates for \(path.debugDescription)")
        expect(
            r.stdout == command + "\n", "AppleScript yields the exact shell command for \(path.debugDescription)")
    }
}
