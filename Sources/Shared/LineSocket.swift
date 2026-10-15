import Foundation

enum SocketError: Error {
    case alreadyRunning
    case cannotBind(Int32)
    case cannotConnect(Int32)
}

private let maxLineBytes = 64 * 1024

private func makeAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
    }
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func lookupUser(_ name: String) -> (uid_t, gid_t)? {
    guard let pw = getpwnam(name) else { return nil }
    return (pw.pointee.pw_uid, pw.pointee.pw_gid)
}

/// Hands the socket file to the app user.
/// - Non-root: nothing to do.
/// - Root: ownerUser must resolve and chown must succeed, else throw.
func applySocketOwnership(
    path: String, ownerUser: String?,
    runningAsRoot: Bool = getuid() == 0,
    lookup: (String) -> (uid_t, gid_t)? = lookupUser,
    chown: (String, uid_t, gid_t) -> Int32 = { Darwin.chown($0, $1, $2) }
) throws {
    guard runningAsRoot else { return }
    guard let user = ownerUser else { throw SocketError.cannotBind(EINVAL) }
    guard let (uid, gid) = lookup(user) else { throw SocketError.cannotBind(ENOENT) }
    guard chown(path, uid, gid) == 0 else { throw SocketError.cannotBind(errno) }
}

private func newSocketFD() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd >= 0 {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    return fd
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

/// Returns false on any error, including a full buffer (EAGAIN).
private func writeAll(_ fd: Int32, _ line: String) -> Bool {
    let bytes = Array((line + "\n").utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}

/// Accumulates bytes and hands back complete lines. Returns nil when a line grows too long.
private struct LineBuffer {
    private var data = Data()

    mutating func feed(_ chunk: Data) -> [String]? {
        data.append(chunk)
        var lines: [String] = []
        while let nl = data.firstIndex(of: 0x0A) {
            var lineData = data[data.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            data = Data(data[data.index(after: nl)...])
        }
        return data.count > maxLineBytes ? nil : lines
    }
}

private func readChunk(_ fd: Int32) -> (data: Data?, closed: Bool) {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    if n > 0 { return (Data(buf[0..<n]), false) }
    if n < 0 && (errno == EAGAIN || errno == EINTR) { return (nil, false) }
    return (nil, true)
}

private func makeReadSource(_ fd: Int32, _ handler: @escaping () -> Void) -> DispatchSourceRead {
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    src.setEventHandler(handler: handler)
    src.setCancelHandler { Darwin.close(fd) }
    return src
}

final class LineSocketServer {
    private final class Connection {
        let fd: Int32
        var buffer = LineBuffer()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    private let path: String
    private let ownerUser: String?
    private var listenSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var bound = false

    init(path: String, ownerUser: String?) {
        self.path = path
        self.ownerUser = ownerUser
    }

    func start(
        onConnect: @escaping (_ reply: @escaping (String) -> Void) -> Void,
        onLine: @escaping (_ line: String, _ reply: @escaping (String) -> Void) -> Void
    ) throws {
        guard var addr = makeAddress(path) else { throw SocketError.cannotBind(ENAMETOOLONG) }
        if try isLive() { throw SocketError.alreadyRunning }
        unlink(path)

        let fd = newSocketFD()
        guard fd >= 0 else { throw SocketError.cannotBind(errno) }

        // Bind under a restrictive umask so the file is never world-accessible.
        let oldMask = umask(0o177)
        let rc = withSockaddr(&addr) { Darwin.bind(fd, $0, $1) }
        let bindErr = errno
        umask(oldMask)
        guard rc == 0 else {
            Darwin.close(fd)
            throw SocketError.cannotBind(bindErr)
        }
        bound = true

        chmod(path, 0o600)
        do {
            try applySocketOwnership(path: path, ownerUser: ownerUser)
        } catch {
            Darwin.close(fd)
            unlink(path)
            bound = false
            throw error
        }
        guard listen(fd, 8) == 0 else {
            let e = errno
            Darwin.close(fd)
            unlink(path)
            bound = false
            throw SocketError.cannotBind(e)
        }
        setNonBlocking(fd)

        let src = makeReadSource(fd) { [weak self] in
            self?.acceptAll(fd, onConnect: onConnect, onLine: onLine)
        }
        listenSource = src
        src.resume()
    }

    func broadcast(_ line: String) {
        for conn in Array(connections.values) { send(line, to: conn) }
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        for conn in Array(connections.values) { drop(conn) }
        if bound {
            unlink(path)
            bound = false
        }
    }

    /// A connect that succeeds means another server owns the path.
    private func isLive() throws -> Bool {
        guard FileManager.default.fileExists(atPath: path), var addr = makeAddress(path) else { return false }
        let probe = newSocketFD()
        guard probe >= 0 else { throw SocketError.cannotBind(errno) }
        defer { Darwin.close(probe) }
        return withSockaddr(&addr) { Darwin.connect(probe, $0, $1) } == 0
    }

    private func acceptAll(
        _ listenFD: Int32,
        onConnect: @escaping (_ reply: @escaping (String) -> Void) -> Void,
        onLine: @escaping (_ line: String, _ reply: @escaping (String) -> Void) -> Void
    ) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setNonBlocking(fd)
            let conn = Connection(fd: fd)
            let reply: (String) -> Void = { [weak self, weak conn] line in
                guard let self, let conn else { return }
                self.send(line, to: conn)
            }
            conn.source = makeReadSource(fd) { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.readable(conn, reply: reply, onLine: onLine)
            }
            connections[fd] = conn
            conn.source?.resume()
            onConnect(reply)
        }
    }

    private func readable(
        _ conn: Connection, reply: @escaping (String) -> Void,
        onLine: (_ line: String, _ reply: @escaping (String) -> Void) -> Void
    ) {
        let (chunk, closed) = readChunk(conn.fd)
        if let chunk {
            guard let lines = conn.buffer.feed(chunk) else { return drop(conn) }
            for line in lines where connections[conn.fd] === conn { onLine(line, reply) }
        }
        if closed { drop(conn) }
    }

    private func send(_ line: String, to conn: Connection) {
        guard connections[conn.fd] === conn else { return }
        if !writeAll(conn.fd, line) { drop(conn) }
    }

    private func drop(_ conn: Connection) {
        guard connections[conn.fd] === conn else { return }
        connections[conn.fd] = nil
        conn.source?.cancel()
        conn.source = nil
    }
}

final class LineSocketClient {
    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = LineBuffer()

    init(path: String) { self.path = path }

    func connect() throws {
        guard fd < 0 else { return }
        guard var addr = makeAddress(path) else { throw SocketError.cannotConnect(ENAMETOOLONG) }
        let s = newSocketFD()
        guard s >= 0 else { throw SocketError.cannotConnect(errno) }
        guard withSockaddr(&addr, { Darwin.connect(s, $0, $1) }) == 0 else {
            let e = errno
            Darwin.close(s)
            throw SocketError.cannotConnect(e)
        }
        setNonBlocking(s)
        fd = s
        buffer = LineBuffer()
        let src = makeReadSource(s) { [weak self] in self?.readable() }
        source = src
        src.resume()
    }

    func send(_ line: String) {
        guard fd >= 0 else { return }
        if !writeAll(fd, line) { peerClosed() }
    }

    /// A local close does not fire `onClose`.
    func close() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func readable() {
        guard fd >= 0 else { return }
        let (chunk, closed) = readChunk(fd)
        if let chunk {
            guard let lines = buffer.feed(chunk) else { return peerClosed() }
            for line in lines where fd >= 0 { onLine?(line) }
        }
        if closed { peerClosed() }
    }

    private func peerClosed() {
        guard fd >= 0 else { return }
        close()
        onClose?()
    }
}
