import Foundation

func runLineSocketTests() {
    testServerFileMode()
    testRoundTripAndBroadcast()
    testStaleSocketFileIsReplaced()
    testSecondLiveServerThrows()
    testClientSeesCloseWhenServerStops()
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
