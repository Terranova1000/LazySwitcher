import AppKit

// Explicit entry point rather than @main: this is a menu-bar agent, and being
// able to see the activation policy set here has saved confusion before.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // belt and braces alongside LSUIElement
app.run()
