import Foundation

/// Starts the root engine through the macOS administrator prompt.
final class EngineLauncher {
    private let enginePath: String

    init(enginePath: String) { self.enginePath = enginePath }

    /// Runs osascript off the main thread. `completion` runs on the main queue.
    func launch(arguments: [String], completion: @escaping (ElevationResult) -> Void) {
        let argv = osascriptArguments(enginePath: enginePath, engineArguments: arguments)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = EngineLauncher.runOsascript(argv)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runOsascript(_ argv: [String]) -> ElevationResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = argv
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return interpretOsascript(status: p.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
    }
}
