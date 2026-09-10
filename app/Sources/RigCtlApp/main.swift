import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let status = StatusController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        status.install()
        // screenshot helper: pop the menu and publish its rect, then quit
        if let frameFile = ProcessInfo.processInfo.environment["RIGCTL_MENU_FRAME"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [status] in
                status.openMenuForCapture(frameFile: frameFile, holdFor: 8)
            }
        }
        if let frameFile = ProcessInfo.processInfo.environment["RIGCTL_CONFIG_FRAME"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [status] in
                status.openConfigForCapture(frameFile: frameFile, holdFor: 8)
            }
        }
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
