import Foundation

/// Keeps the one-shot client alive while the run loop spins.
private var activeClient: LineSocketClient?

private func connectedClient() -> LineSocketClient {
    let c = LineSocketClient(path: controlSocketPath)
    activeClient = c
    c.onClose = { fail("The alarm closed the connection before replying.") }
    do {
        try c.connect()
    } catch SocketError.cannotConnect(let e) {
        fail(connectErrorText(e))
    } catch {
        fail("Cannot reach the alarm: \(error)")
    }
    return c
}

private func exitAfter(_ seconds: Double, _ message: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { fail(message) }
}

/// Prints the engine's current state, then exits. Needs no root.
func startStatusCommand() {
    let c = connectedClient()
    c.onLine = { line in
        guard case .state(let s)? = decodeEngineMessage(line) else { return }
        print(describe(s))
        exit(0)
    }
    c.send(encode(ClientCommand.status))
    exitAfter(5, "The alarm did not answer.")
}

/// Asks for the password, sends it, prints the result, then exits. Needs no root.
func startDisarmCommand() {
    let c = connectedClient()
    guard let p = getpass("Password to disarm: ") else { fail("No terminal to read the password from.") }
    c.onLine = { line in
        switch decodeEngineMessage(line) {
        case .ok?:
            print("Disarmed.")
            exit(0)
        case .error(let code)?:
            fail(disarmErrorText(code))
        default:
            break
        }
    }
    c.send(encode(ClientCommand.disarm(password: String(cString: p))))
    exitAfter(15, "The alarm did not answer.")
}
