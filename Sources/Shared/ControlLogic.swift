import Foundation

enum ControlDecision: Equatable {
    case reply(EngineMessage)
    case cancel
    case verify(password: String)
}

/// What the engine does with a client command. Pure, so it can be tested.
/// - STATUS always answers with the current state.
/// - CANCEL only before arming completes.
/// - DISARM only when armed, degraded or triggered, and not rate limited.
func decideControl(_ command: ClientCommand, state: AlarmState, limiter: AttemptLimiter, now: Date) -> ControlDecision {
    switch command {
    case .status:
        return .reply(.state(state))
    case .cancel:
        switch state {
        case .countdown, .calibrating: return .cancel
        default: return .reply(.error("not-cancellable"))
        }
    case .disarm(let password):
        switch state {
        case .armed, .degraded, .triggered:
            if limiter.isBlocked(at: now) { return .reply(.error("rate-limited")) }
            return .verify(password: password)
        default:
            return .reply(.error("not-armed"))
        }
    }
}

/// Records the outcome of a password check and returns the reply.
func passwordResult(ok: Bool, limiter: inout AttemptLimiter, now: Date) -> EngineMessage {
    if ok {
        limiter.recordSuccess()
        return .ok
    }
    limiter.recordFailure(at: now)
    return .error("wrong-password")
}

func describe(_ state: AlarmState) -> String {
    switch state {
    case .disarmed: return "Disarmed"
    case .countdown(let n): return "Arming in \(n) s"
    case .calibrating: return "Calibrating"
    case .armed: return "Armed"
    case .degraded(let r): return "Armed (degraded): \(r)"
    case .triggered(let r): return "ALARM TRIGGERED: \(r)"
    }
}

func disarmErrorText(_ code: String) -> String {
    switch code {
    case "wrong-password": return "Wrong password."
    case "rate-limited": return "Too many wrong passwords. Wait and try again."
    case "not-armed": return "The alarm is not armed."
    default: return "Engine error: \(code)"
    }
}

func connectErrorText(_ err: Int32) -> String {
    switch err {
    case ENOENT, ECONNREFUSED: return "No alarm is running."
    default: return "Cannot reach the alarm: \(String(cString: strerror(err)))"
    }
}
