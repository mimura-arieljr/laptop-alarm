import Foundation

let ntfyServer = "https://ntfy.sh"

/// The topic name is the only secret, so it is random and stored in a 0600 file in the user's home.
func makePushTopic() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    var rng = SystemRandomNumberGenerator()
    return "laptop-alarm-" + String((0..<24).map { _ in chars.randomElement(using: &rng)! })
}

func pushTopicPath(user: String, homeOverride: String? = nil) -> String? {
    guard let home = homeOverride ?? NSHomeDirectoryForUser(user) else { return nil }
    return home + "/.laptop-alarm-ntfy-topic"
}

func loadPushTopic(user: String, homeOverride: String? = nil) -> String? {
    guard let path = pushTopicPath(user: user, homeOverride: homeOverride),
          let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

func createPushTopic(user: String, homeOverride: String? = nil) -> String? {
    guard let path = pushTopicPath(user: user, homeOverride: homeOverride) else { return nil }
    let topic = makePushTopic()
    guard (try? topic.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
    chmod(path, 0o600)
    if geteuid() == 0 { run("/usr/sbin/chown", [user, path]) }
    return topic
}

/// True on HTTP 200.
func sendPush(topic: String, title: String, message: String) -> Bool {
    let out = run("/usr/bin/curl", ["-sS", "-m", "10", "-o", "/dev/null", "-w", "%{http_code}",
                                    "-H", "Title: \(title)", "-H", "Priority: urgent", "-H", "Tags: rotating_light",
                                    "-d", message, "\(ntfyServer)/\(topic)"])
    return out.hasSuffix("200")
}
