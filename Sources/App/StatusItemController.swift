import AppKit

final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let client = LineSocketClient(path: controlSocketPath)
    private let enginePath: String?
    private var settings: AppSettings
    private var state = AppState.disarmed
    private var warnings = WarningList()

    private var voiceDirectory: String?
    private var connectTimer: Timer?
    private var flashTimer: Timer?
    private var flashOn = true
    private var promptOpen = false
    private var awaitingDisarm = false

    private let phoneAlerts = PhoneAlertsWindowController()
    private let statusWidth = 44
    private let spokenWarning = "This laptop is being stolen"

    override init() {
        settings = StatusItemController.loadSettings()
        enginePath = StatusItemController.locateEngine()
        super.init()
        menu.autoenablesItems = false
        statusItem.menu = menu
        removeStaleVoiceDirectories()
        client.onLine = { [weak self] line in self?.handle(line) }
        client.onClose = { [weak self] in self?.apply(.connectionClosed) }
        phoneAlerts.onTopicCreated = { [weak self] in self?.render() }
        // A running engine greets with its state, which replaces this one.
        try? client.connect()
        if enginePath == nil { state = .failed("Alarm engine not found.") }
        render()
    }

    // MARK: State

    private func apply(_ event: AppEvent) {
        let old = state
        state = reduce(state, event)
        if state == .disarmed && old != .disarmed { warnings.clear() }
        render()
    }

    private func handle(_ line: String) {
        guard let message = decodeEngineMessage(line) else { return }
        switch message {
        case .state:
            removeVoiceDirectory()
            apply(.engine(message))
        case .warning(let text):
            warnings.add(text)
            render()
        case .ok:
            awaitingDisarm = false
        case .error(let code):
            handleError(code)
        }
    }

    private func handleError(_ code: String) {
        guard awaitingDisarm else { return }
        awaitingDisarm = false
        switch code {
        case "wrong-password":
            DispatchQueue.main.async { [weak self] in
                showMessage("Wrong password")
                self?.disarm()
            }
        case "rate-limited":
            DispatchQueue.main.async { showMessage("Too many attempts. Wait a few seconds.") }
        default:
            break
        }
    }

    // MARK: Actions

    @objc private func arm() {
        guard presentation(for: state).armEnabled else { return }
        apply(.armTapped)
        guard let enginePath else {
            apply(.elevation(.failed("Alarm engine not found.")))
            return
        }
        let baseArguments = settings.engineArguments(user: NSUserName())
        let text = spokenWarning
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let voice = StatusItemController.renderVoice(text: text)
            DispatchQueue.main.async {
                guard let self else { return }
                self.voiceDirectory = voice?.directory
                let arguments = baseArguments + (voice.map { ["--voice-file", $0.file] } ?? [])
                EngineLauncher(enginePath: enginePath).launch(arguments: arguments) { [weak self] result in
                    self?.launched(result)
                }
            }
        }
    }

    private func launched(_ result: ElevationResult) {
        apply(.elevation(result))
        if result == .started {
            startConnectRetries()
        } else {
            removeVoiceDirectory()
        }
    }

    private func startConnectRetries() {
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            guard self.state == .launching else { return self.stopConnectRetries() }
            do {
                try self.client.connect()
                self.stopConnectRetries()
            } catch {
                guard Date() >= deadline else { return }
                self.stopConnectRetries()
                self.removeVoiceDirectory()
                self.apply(.connectTimedOut)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        connectTimer = timer
    }

    private func stopConnectRetries() {
        connectTimer?.invalidate()
        connectTimer = nil
    }

    @objc private func cancel() {
        client.send(encode(ClientCommand.cancel))
    }

    @objc private func disarm() {
        guard !promptOpen else { return }
        promptOpen = true
        defer { promptOpen = false }
        guard let password = promptForPassword(title: "Disarm laptop alarm", message: "Enter your macOS password.")
        else { return }
        awaitingDisarm = true
        client.send(encode(ClientCommand.disarm(password: password)))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func copyRecoveryCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo pmset -a disablesleep 0", forType: .string)
    }

    @objc private func openPhoneAlerts() {
        phoneAlerts.show()
    }

    @objc private func pickSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Sensitivity(rawValue: raw) else { return }
        settings.sensitivity = value
        saveSettings()
    }

    @objc private func pickSiren(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = SirenLevel(rawValue: raw) else { return }
        settings.siren = value
        saveSettings()
    }

    // MARK: Settings

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
            let saved = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return saved
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
        render()
    }

    // MARK: Engine and voice file

    private static func locateEngine() -> String? {
        let resourceDir = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.resourceURL?.path : nil
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "."
        return chooseEnginePath(
            resourceDir: resourceDir, executableDir: executableDir,
            exists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Renders the spoken warning as the user into a private 0700 directory.
    private static func renderVoice(text: String) -> (directory: String, file: String)? {
        let directory = NSTemporaryDirectory() + voiceDirectoryPrefix + UUID().uuidString
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let file = directory + "/voice.wav"
        if renderVoiceFile(text: text, to: file) { return (directory, file) }
        try? FileManager.default.removeItem(atPath: directory)
        return nil
    }

    private func removeVoiceDirectory() {
        guard let directory = voiceDirectory else { return }
        voiceDirectory = nil
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func removeStaleVoiceDirectories() {
        let root = NSTemporaryDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in staleVoiceDirectories(in: names) {
            try? FileManager.default.removeItem(atPath: root + name)
        }
    }

    // MARK: Rendering

    private func render() {
        let p = presentation(for: state)
        renderIcon(p)
        renderMenu(p)
    }

    private func renderIcon(_ p: MenuPresentation) {
        if p.flashing {
            startFlashing()
        } else {
            flashTimer?.invalidate()
            flashTimer = nil
            flashOn = true
        }
        let name = flashOn ? p.iconName : "exclamationmark.triangle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Laptop Alarm")
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Laptop Alarm")
        image?.isTemplate = true
        guard let button = statusItem.button else { return }
        button.image = image
        switch p.tint {
        case .none: button.contentTintColor = nil
        case .red: button.contentTintColor = .systemRed
        case .orange: button.contentTintColor = .systemOrange
        }
    }

    private func startFlashing() {
        guard flashTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.flashOn.toggle()
            self.renderIcon(presentation(for: self.state))
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func renderMenu(_ p: MenuPresentation) {
        menu.removeAllItems()
        for line in statusDisplayLines(p.statusText, width: statusWidth) { menu.addItem(disabledItem(line)) }
        for warning in warnings.items {
            let lines = wrapText("Warning: " + warning, width: statusWidth)
            for line in lines { menu.addItem(disabledItem(line)) }
        }
        if state == .lost {
            menu.addItem(actionItem("Copy recovery command", #selector(copyRecoveryCommand)))
        }
        menu.addItem(.separator())
        if p.cancelVisible {
            menu.addItem(actionItem("Cancel", #selector(cancel)))
        } else if p.disarmVisible {
            menu.addItem(actionItem("Disarm...", #selector(disarm)))
        } else {
            let arm = actionItem("Arm", #selector(arm))
            arm.isEnabled = p.armEnabled
            menu.addItem(arm)
        }
        menu.addItem(.separator())
        menu.addItem(submenuItem("Sensitivity", Sensitivity.allCases, current: settings.sensitivity, #selector(pickSensitivity)))
        menu.addItem(submenuItem("Siren volume", SirenLevel.allCases, current: settings.siren, #selector(pickSiren)))
        let phoneTitle = loadPushTopic(user: NSUserName()) != nil ? "Phone alerts: set up" : "Phone alerts: not set up"
        menu.addItem(actionItem(phoneTitle, #selector(openPhoneAlerts)))
        menu.addItem(.separator())
        let quit = actionItem("Quit", #selector(quit))
        quit.isEnabled = p.quitEnabled
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func submenuItem<T: RawRepresentable & Equatable>(
        _ title: String, _ options: [T], current: T, _ action: Selector
    ) -> NSMenuItem where T.RawValue == String {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for option in options {
            let item = actionItem(option.rawValue.capitalized, action)
            item.representedObject = option.rawValue
            item.state = option == current ? .on : .off
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }
}
