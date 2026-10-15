import Foundation

enum AppState: Equatable {
    case disarmed
    case failed(String)
    case launching
    case countdown(Int)
    case calibrating
    case armed
    case armedDegraded(String)
    case triggered(String)
    case lost
}

enum AppEvent {
    case armTapped
    case elevation(ElevationResult)
    case engine(EngineMessage)
    case connectionClosed
    case connectTimedOut
}

func reduce(_ s: AppState, _ e: AppEvent) -> AppState {
    switch e {
    case .armTapped:
        switch s {
        case .disarmed, .failed: return .launching
        default: return s
        }
    case .elevation(let result):
        guard s == .launching else { return s }
        switch result {
        case .started: return s
        case .cancelled: return .disarmed
        case .failed(let message): return .failed(message)
        }
    case .engine(let message):
        guard case .state(let alarm) = message else { return s }
        switch alarm {
        case .disarmed: return .disarmed
        case .countdown(let n): return .countdown(n)
        case .calibrating: return .calibrating
        case .armed: return .armed
        case .degraded(let reason): return .armedDegraded(reason)
        case .triggered(let reason): return .triggered(reason)
        }
    case .connectionClosed:
        switch s {
        case .armed, .armedDegraded, .triggered, .lost: return .lost
        case .launching, .countdown, .calibrating: return .disarmed
        case .disarmed, .failed: return s
        }
    case .connectTimedOut:
        return s == .launching ? .failed("The alarm engine did not start.") : s
    }
}

struct MenuPresentation: Equatable {
    enum Tint { case none, red, orange }

    var statusText: String
    var iconName: String
    var tint: Tint
    var flashing: Bool
    var armEnabled: Bool
    var cancelVisible: Bool
    var disarmVisible: Bool
    var quitEnabled: Bool
}

func presentation(for s: AppState) -> MenuPresentation {
    func make(
        _ text: String, icon: String, tint: MenuPresentation.Tint = .none, flashing: Bool = false,
        arm: Bool = false, cancel: Bool = false, disarm: Bool = false, quit: Bool = false
    ) -> MenuPresentation {
        MenuPresentation(
            statusText: text, iconName: icon, tint: tint, flashing: flashing, armEnabled: arm,
            cancelVisible: cancel, disarmVisible: disarm, quitEnabled: quit)
    }
    switch s {
    case .disarmed:
        return make("Disarmed", icon: "lock.open", arm: true, quit: true)
    case .failed(let message):
        return make("Failed: \(message)", icon: "exclamationmark.triangle", tint: .orange, arm: true, quit: true)
    case .launching:
        return make("Starting alarm engine", icon: "lock.open")
    case .countdown(let n):
        return make("Arming in \(n) s", icon: "lock", cancel: true)
    case .calibrating:
        return make("Calibrating", icon: "lock")
    case .armed:
        return make("Armed", icon: "lock.fill", tint: .red, disarm: true)
    case .armedDegraded(let reason):
        return make("Armed, degraded: \(reason)", icon: "lock.trianglebadge.exclamationmark", tint: .orange, disarm: true)
    case .triggered(let reason):
        return make("ALARM: \(reason)", icon: "bell.fill", tint: .red, flashing: true, disarm: true)
    case .lost:
        return make(
            "Lost contact with the engine. If the Mac will not sleep, run: sudo pmset -a disablesleep 0",
            icon: "exclamationmark.triangle", tint: .orange, quit: true)
    }
}
