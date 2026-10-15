import Foundation

func runLineSocketTests() {
    testServerFileMode()
    testRoundTripAndBroadcast()
    testStaleSocketFileIsReplaced()
    testSecondLiveServerThrows()
    testClientSeesCloseWhenServerStops()
    testDisarmLineThroughSocket()
    testOwnershipNonRootSkipsChown()
    testOwnershipRootFailuresThrow()
}

func testDisarmLineThroughSocket() {
    let path = tempSocketPath()
    let server = LineSocketServer(path: path, ownerUser: nil)
    let client = LineSocketClient(path: path)
    defer { client.close(); server.stop(); unlink(path) }
    let pw = "\u{FEFF}p@ss \"w\" \\ e\u{301} 日本 🔐"
    var got: ClientCommand?
    do {
        try server.start(onConnect: { _ in }, onLine: { line, _ in got = decodeClientCommand(line) })
        try client.connect()
    } catch { expect(false, "setup failed: \(error)"); return }
    client.send(encode(ClientCommand.disarm(password: pw)))
    pump(until: { got != nil })
    if case .disarm(let p)? = got {
        expect(Array(p.utf8) == Array(pw.utf8), "password bytes survive the socket")
    } else {
        expect(false, "disarm line arrived and decoded")
    }
}

func testOwnershipNonRootSkipsChown() {
    var called = false
    do {
        try applySocketOwnership(
            path: "/nonexistent", ownerUser: nil, runningAsRoot: false,
            lookup: { _ in nil }, chown: { _, _, _ in called = true; return -1 })
        try applySocketOwnership(
            path: "/nonexistent", ownerUser: "alice", runningAsRoot: false,
            lookup: { _ in nil }, chown: { _, _, _ in called = true; return -1 })
    } catch { expect(false, "non-root must succeed, got \(error)") }
    expect(!called, "non-root never calls chown")
}

func testOwnershipRootFailuresThrow() {
    func fails(
        _ user: String?, lookup: @escaping (String) -> (uid_t, gid_t)?,
        chown: @escaping (String, uid_t, gid_t) -> Int32
    ) -> Bool {
        do {
            try applySocketOwnership(path: "/p", ownerUser: user, runningAsRoot: true, lookup: lookup, chown: chown)
            return false
        } catch { return true }
    }
    expect(fails(nil, lookup: { _ in (1, 2) }, chown: { _, _, _ in 0 }), "root without ownerUser throws")
    expect(fails("ghost", lookup: { _ in nil }, chown: { _, _, _ in 0 }), "root with unknown user throws")
    expect(fails("alice", lookup: { _ in (501, 20) }, chown: { _, _, _ in -1 }), "root with failing chown throws")
    var args: (String, uid_t, gid_t)?
    do {
        try applySocketOwnership(
            path: "/p", ownerUser: "alice", runningAsRoot: true,
            lookup: { _ in (501, 20) }, chown: { args = ($0, $1, $2); return 0 })
    } catch { expect(false, "root happy path should succeed, got \(error)") }
    expect(args?.0 == "/p" && args?.1 == 501 && args?.2 == 20, "chown called with resolved uid and gid")
}

func tempSocketPath() -> String {
    "/tmp/la-\(UUID().uuidString.prefix(8)).sock"
}

func pump(until done: () -> Bool, timeout: TimeInterval = 2) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func testServerFileMode() {
    let path = tempSocketPath()
    let server = LineSocketServer(path: path, ownerUser: nil)
    defer { server.stop(); unlink(path) }
    do { try server.start(onConnect: { _ in }, onLine: { _, _ in }) } catch {
        expect(false, "start failed: \(error)"); return
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
    expect(mode == 0o600, "socket mode is 0600, got \(String(describing: mode))")
}

func testRoundTripAndBroadcast() {
    let path = tempSocketPath()
    let server = LineSocketServer(path: path, ownerUser: nil)
    let client = LineSocketClient(path: path)
    defer { client.close(); server.stop(); unlink(path) }
    var connects = 0
    var serverGot: [String] = []
    var clientGot: [String] = []
    do {
        try server.start(
            onConnect: { _ in connects += 1 },
            onLine: { line, reply in serverGot.append(line); reply("world") })
        client.onLine = { clientGot.append($0) }
        try client.connect()
    } catch { expect(false, "setup failed: \(error)"); return }
    client.send("hello")
    pump(until: { !clientGot.isEmpty })
    expect(serverGot == ["hello"], "server got hello, got \(serverGot)")
    expect(clientGot == ["world"], "client got world, got \(clientGot)")
    server.broadcast("x")
    pump(until: { clientGot.count >= 2 })
    expect(clientGot == ["world", "x"], "broadcast reached client, got \(clientGot)")
    expect(connects == 1, "onConnect fired once, got \(connects)")
}

func testStaleSocketFileIsReplaced() {
    let path = tempSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("junk".utf8))
    let server = LineSocketServer(path: path, ownerUser: nil)
    defer { server.stop(); unlink(path) }
    do {
        try server.start(onConnect: { _ in }, onLine: { _, _ in })
        expect(true, "")
    } catch { expect(false, "stale file should not stop start: \(error)") }
}

func testSecondLiveServerThrows() {
    let path = tempSocketPath()
    let first = LineSocketServer(path: path, ownerUser: nil)
    let second = LineSocketServer(path: path, ownerUser: nil)
    defer { first.stop(); unlink(path) }
    do { try first.start(onConnect: { _ in }, onLine: { _, _ in }) } catch {
        expect(false, "first start failed: \(error)"); return
    }
    do {
        try second.start(onConnect: { _ in }, onLine: { _, _ in })
        expect(false, "second start should throw")
        second.stop()
    } catch SocketError.alreadyRunning {
        expect(true, "")
    } catch { expect(false, "wrong error: \(error)") }
    expect(FileManager.default.fileExists(atPath: path), "live socket file survives a failed second start")
}

func testClientSeesCloseWhenServerStops() {
    let path = tempSocketPath()
    let server = LineSocketServer(path: path, ownerUser: nil)
    let client = LineSocketClient(path: path)
    defer { client.close(); server.stop(); unlink(path) }
    var connected = false
    var closed = false
    do {
        try server.start(onConnect: { _ in connected = true }, onLine: { _, _ in })
        client.onClose = { closed = true }
        try client.connect()
    } catch { expect(false, "setup failed: \(error)"); return }
    pump(until: { connected })
    server.stop()
    pump(until: { closed })
    expect(closed, "client onClose fired after server stop")
}
