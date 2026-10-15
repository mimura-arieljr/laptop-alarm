import AppKit

/// Password dialog. Returns nil on cancel or an empty entry.
/// - The field is cleared before returning.
/// - The caller must not log or store the result.
func promptForPassword(title: String, message: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Disarm")
    alert.addButton(withTitle: "Cancel")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    let response = alert.runModal()
    alert.window.makeFirstResponder(nil)
    let entered = field.stringValue
    field.stringValue = ""
    guard response == .alertFirstButtonReturn, !entered.isEmpty else { return nil }
    return entered
}

func showMessage(_ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = text
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
