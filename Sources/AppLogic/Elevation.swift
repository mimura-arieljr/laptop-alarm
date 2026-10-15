import Foundation

enum ElevationResult: Equatable {
    case started
    case cancelled
    case failed(String)
}

func interpretOsascript(status: Int32, stderr: String) -> ElevationResult {
    if status == 0 { return .started }
    if stderr.contains("User canceled. (-128)") { return .cancelled }
    return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// POSIX single quoting. Inside '...' only the quote itself is special.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Escapes text for an AppleScript string literal.
private func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// argv for /usr/bin/osascript. The command runs as root, so every word is shell quoted.
func osascriptArguments(enginePath: String, engineArguments: [String]) -> [String] {
    let command = ([enginePath] + engineArguments).map(shellQuote).joined(separator: " ")
    let script = "do shell script \"" + appleScriptEscape(command + " > /dev/null 2>&1 &")
        + "\" with administrator privileges"
    return ["-e", script]
}
