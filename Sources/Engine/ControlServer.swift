import Foundation

/// Serves the control socket for headless mode.
/// - One limiter for the whole process, so reconnecting never resets the backoff.
/// - Everything runs on the main queue.
final class ControlServer {
    private let server: LineSocketServer
    private weak var alarm: Alarm?
    private var limiter = AttemptLimiter()
    private var verifying = false

    init(alarm: Alarm, ownerUser: String) {
        self.alarm = alarm
        server = LineSocketServer(path: controlSocketPath, ownerUser: ownerUser)
    }

    /// Throws `SocketError.alreadyRunning` when another engine owns the socket.
    func start() throws {
        try server.start(
            onConnect: { [weak self] reply in self?.greet(reply) },
            onLine: { [weak self] line, reply in self?.handle(line, reply) })
    }

    func broadcast(_ line: String) { server.broadcast(line) }
    func stop() { server.stop() }

    private func greet(_ reply: (String) -> Void) {
        guard let alarm else { return }
        reply(encode(.state(alarm.current)))
        for w in alarm.warnings { reply(encode(.warning(w))) }
    }

    private func handle(_ line: String, _ reply: @escaping (String) -> Void) {
        guard let alarm else { return }
        guard let command = decodeClientCommand(line) else { return reply(encode(.error("bad-command"))) }
        if verifying, case .disarm = command { return reply(encode(.error("rate-limited"))) }
        switch decideControl(command, state: alarm.current, limiter: limiter, now: Date()) {
        case .reply(let m):
            reply(encode(m))
        case .cancel:
            alarm.cancelFromClient()
        case .verify(let password):
            verify(password, user: alarm.user, reply: reply)
        }
    }

    /// Checks off the main queue so a slow lookup never blocks signals or the siren.
    /// - `verifying` rejects a second DISARM while one is in flight.
    private func verify(_ password: String, user: String, reply: @escaping (String) -> Void) {
        verifying = true
        DispatchQueue.global().async { [self] in
            let ok = verifyPassword(user: user, password: password)
            DispatchQueue.main.async { [self] in
                verifying = false
                reply(encode(passwordResult(ok: ok, limiter: &limiter, now: Date())))
                if ok { alarm?.disarm() }
            }
        }
    }
}
