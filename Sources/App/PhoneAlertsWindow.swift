import AppKit

final class PhoneAlertsWindowController: NSObject {
    /// Called after a topic is created, so the menu title can refresh.
    var onTopicCreated: (() -> Void)?

    private var window: NSWindow?
    private let topicLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "Create topic", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let testButton = NSButton(title: "Send test", target: nil, action: nil)

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Phone alerts"
        window.isReleasedWhenClosed = false
        window.center()

        topicLabel.isSelectable = true
        topicLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        topicLabel.lineBreakMode = .byCharWrapping
        topicLabel.maximumNumberOfLines = 0

        let instructions = NSTextField(
            wrappingLabelWithString:
                "In the ntfy app, tap +, enter this topic name, and keep the default server (ntfy.sh).")

        for (button, action) in [
            (createButton, #selector(createTopic)), (copyButton, #selector(copyTopic)),
            (testButton, #selector(sendTest)),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [createButton, copyButton, testButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [topicLabel, buttons, statusLabel, instructions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalToConstant: 420),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topicLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return window
    }

    private func refresh() {
        let topic = loadPushTopic(user: NSUserName())
        topicLabel.stringValue = topic ?? "No topic yet."
        createButton.isHidden = topic != nil
        copyButton.isHidden = topic == nil
        testButton.isHidden = topic == nil
    }

    @objc private func createTopic() {
        if createPushTopic(user: NSUserName()) == nil {
            statusLabel.stringValue = "Could not save the topic."
            return
        }
        statusLabel.stringValue = ""
        refresh()
        onTopicCreated?()
    }

    @objc private func copyTopic() {
        guard let topic = loadPushTopic(user: NSUserName()) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
        statusLabel.stringValue = "Copied."
    }

    @objc private func sendTest() {
        guard let topic = loadPushTopic(user: NSUserName()) else { return }
        testButton.isEnabled = false
        statusLabel.stringValue = "Sending..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = sendPush(topic: topic, title: "Laptop Alarm", message: "Test alert from your Mac.")
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true
                self?.statusLabel.stringValue = ok ? "Sent. Check your phone." : "Send failed. Check the network."
            }
        }
    }
}
