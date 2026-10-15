import Foundation

enum Sensitivity: String, Codable, CaseIterable {
    case low, normal, high

    var tiltDegrees: Double {
        switch self {
        case .low: return 5.0
        case .normal: return 2.0
        case .high: return 1.0
        }
    }

    var shockG: Double {
        switch self {
        case .low: return 0.15
        case .normal: return 0.09
        case .high: return 0.06
        }
    }
}

enum SirenLevel: String, Codable, CaseIterable {
    case low, medium, full

    var volume: Double {
        switch self {
        case .low: return 0.25
        case .medium: return 0.5
        case .full: return 1.0
        }
    }
}

struct AppSettings: Codable, Equatable {
    var sensitivity = Sensitivity.normal
    var siren = SirenLevel.full

    func engineArguments(user: String) -> [String] {
        [
            "arm", "--headless", "--user", user, "--countdown", "10",
            "--tilt", String(sensitivity.tiltDegrees),
            "--shock", String(sensitivity.shockG),
            "--volume", String(siren.volume),
        ]
    }
}
