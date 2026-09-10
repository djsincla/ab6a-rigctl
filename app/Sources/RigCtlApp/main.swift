import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let status = StatusController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        status.install()
    }
}

// Top-level code in main.swift already runs on the main thread; assumeIsolated
// tells the compiler what the runtime guarantees.
let delegate = MainActor.assumeIsolated { AppDelegate() }
// A build-time smoke test for the menu construction path.
if let mode = ProcessInfo.processInfo.environment["RIGCTL_SELFTEST"] {
    let lines = MainActor.assumeIsolated { () -> [String] in
        if mode == "config" {
            let state = AppState()
            state.refresh()
            return ConfigWindowController(state: state, onSave: {}).selfTest()
        }
        return StatusController().selfTest()
    }
    lines.forEach { print($0) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // menu bar only, no Dock icon
app.delegate = delegate
app.run()
