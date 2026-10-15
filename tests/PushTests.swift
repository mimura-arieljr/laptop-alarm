import Foundation

func runPushTests() {
    testPushTopicFormat()
    testCreateThenLoadTopic()
    testLoadMissingTopicIsNil()
}

func makeTempHome() -> String {
    let dir = NSTemporaryDirectory() + "laptop-alarm-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func testPushTopicFormat() {
    let a = makePushTopic(), b = makePushTopic()
    let ok = a.range(of: "^laptop-alarm-[a-z0-9]{24}$", options: .regularExpression) != nil
    expect(ok, "topic format, got \(a)")
    expect(a != b, "two topics differ")
}

func testCreateThenLoadTopic() {
    let home = makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let topic = createPushTopic(user: "alice", homeOverride: home)
    expect(topic != nil, "createPushTopic returns a topic")
    let path = home + "/.laptop-alarm-ntfy-topic"
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
    expect(mode == 0o600, "topic file mode is 0600, got \(String(describing: mode))")
    expect(loadPushTopic(user: "alice", homeOverride: home) == topic, "load returns the created topic")
}

func testLoadMissingTopicIsNil() {
    let home = makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    expect(loadPushTopic(user: "alice", homeOverride: home) == nil, "missing topic file loads as nil")
}
