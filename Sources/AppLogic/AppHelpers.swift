import Foundation

let voiceDirectoryPrefix = "laptop-alarm-voice-"
let engineFileName = "laptop-alarm"

/// Bundled engine first, then the one next to the executable (dev build).
func chooseEnginePath(resourceDir: String?, executableDir: String, exists: (String) -> Bool) -> String? {
    let candidates = [resourceDir, executableDir].compactMap { $0 }.map { $0 + "/" + engineFileName }
    return candidates.first(where: exists)
}

/// Leftover voice directories from earlier runs, never the live one.
func staleVoiceDirectories(in names: [String], keeping current: String? = nil) -> [String] {
    names.filter { $0.hasPrefix(voiceDirectoryPrefix) && $0 != current }
}

/// Engine warnings, de-duplicated by text and kept in arrival order.
struct WarningList: Equatable {
    private(set) var items: [String] = []

    mutating func add(_ text: String) {
        if !items.contains(text) { items.append(text) }
    }

    mutating func clear() { items.removeAll() }
}

/// Greedy word wrap. A word longer than `width` stays on its own line.
func wrapText(_ text: String, width: Int) -> [String] {
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ") {
        if line.isEmpty {
            line = String(word)
        } else if line.count + 1 + word.count <= width {
            line += " " + word
        } else {
            lines.append(line)
            line = String(word)
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// Wrapped menu lines for a status text. A `sudo ...` command is never split.
func statusDisplayLines(_ text: String, width: Int) -> [String] {
    guard let r = text.range(of: "sudo ") else { return wrapText(text, width: width) }
    return wrapText(String(text[..<r.lowerBound]), width: width) + [String(text[r.lowerBound...])]
}
