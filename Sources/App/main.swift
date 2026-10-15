import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusItemController()
app.run()
