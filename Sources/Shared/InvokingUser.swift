import Foundation

/// The human account behind a root process.
/// - A `--user NAME` flag wins and is never overridden when rejected.
/// - Otherwise `SUDO_USER`. Root and empty are rejected.
func resolveInvokingUser(arguments: [String], environment: [String: String]) -> String? {
    let name: String?
    if let i = arguments.firstIndex(of: "--user") {
        name = i + 1 < arguments.count ? arguments[i + 1] : ""
    } else {
        name = environment["SUDO_USER"]
    }
    guard let name, !name.isEmpty, name != "root" else { return nil }
    return name
}
