import Foundation

let controlSocketPath = "/var/run/laptop-alarm.sock"

enum AlarmState: Equatable {
    case disarmed
    case countdown(Int)
    case calibrating
    case armed
    case degraded(String)
    case triggered(String)
}

enum EngineMessage: Equatable {
    case state(AlarmState)
    case warning(String)
    case ok
    case error(String)
}

enum ClientCommand: Equatable {
    case status
    case cancel
    case disarm(password: String)
}

/// Free text must stay on one line.
private func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}

/// The text after `word`, or nil when the line is not `word` or `word <rest>`.
private func rest(of line: String, after word: String) -> String? {
    if line == word { return "" }
    if line.hasPrefix(word + " ") { return String(line.dropFirst(word.count + 1)) }
    return nil
}

func encode(_ m: EngineMessage) -> String {
    switch m {
    case .state(.disarmed): return "STATE disarmed"
    case .state(.countdown(let n)): return "STATE countdown \(n)"
    case .state(.calibrating): return "STATE calibrating"
    case .state(.armed): return "STATE armed"
    case .state(.degraded(let r)): return "STATE degraded \(oneLine(r))"
    case .state(.triggered(let r)): return "STATE triggered \(oneLine(r))"
    case .warning(let t): return "WARN \(oneLine(t))"
    case .ok: return "OK"
    case .error(let code): return "ERR \(oneLine(code))"
    }
}

func decodeEngineMessage(_ line: String) -> EngineMessage? {
    if line == "OK" { return .ok }
    if let t = rest(of: line, after: "WARN") { return .warning(t) }
    if let c = rest(of: line, after: "ERR") { return .error(c) }
    guard let s = rest(of: line, after: "STATE") else { return nil }
    switch s {
    case "disarmed": return .state(.disarmed)
    case "calibrating": return .state(.calibrating)
    case "armed": return .state(.armed)
    default: break
    }
    if let n = rest(of: s, after: "countdown"), let secs = Int(n) { return .state(.countdown(secs)) }
    if let r = rest(of: s, after: "degraded") { return .state(.degraded(r)) }
    if let r = rest(of: s, after: "triggered") { return .state(.triggered(r)) }
    return nil
}

func encode(_ c: ClientCommand) -> String {
    switch c {
    case .status: return "STATUS"
    case .cancel: return "CANCEL"
    case .disarm(let pw): return "DISARM " + Data(pw.utf8).base64EncodedString()
    }
}

func decodeClientCommand(_ line: String) -> ClientCommand? {
    switch line {
    case "STATUS": return .status
    case "CANCEL": return .cancel
    default: break
    }
    guard line.hasPrefix("DISARM "),
        let data = Data(base64Encoded: String(line.dropFirst(7))),
        let pw = String(data: data, encoding: .utf8)
    else { return nil }
    return .disarm(password: pw)
}
