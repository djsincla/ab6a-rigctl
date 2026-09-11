import AppKit

/// The menu bar item and its menu.
///
/// Deliberately AppKit rather than SwiftUI: a SwiftUI executable built by
/// SwiftPM links SwiftUICore directly, which is not allowed, and AttributeGraph
/// aborts on the first layout pass. NSStatusItem has no such problem.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let state = AppState()
    private let item = NSStatusItem.self
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var configWindow: ConfigWindowController?
    /// The reading line for each daemon, kept so it can be refreshed in place
    /// while the menu is open - rebuilding a tracking menu would close it.
    private var readingItems: [String: NSMenuItem] = [:]
    private var menuOpen = false
    private var tick = 0

    /// The amber of the app icon's radiating arcs, for the menu bar glyph.
    private static let accent = NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.13, alpha: 1)

    /// Frequency readout. Menu items are drawn dimmed when disabled, so this is
    /// a deeper, heavier orange than the icon tint - and it flips lighter in a
    /// dark menu, where a dark orange would disappear.
    private static let frequencyColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.24, alpha: 1)
            : NSColor(calibratedRed: 0.76, green: 0.29, blue: 0.01, alpha: 1)
    }

    /// Radio name and mode sit above secondary grey so they stay legible.
    private static let nameColor = NSColor.labelColor
    private static let modeColor = NSColor.labelColor.withAlphaComponent(0.88)
    private static let detailColor = NSColor.labelColor.withAlphaComponent(0.70)

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        // AppKit dims disabled items, which washes out the radio name, the
        // reading and the mode no matter what colour they are given. Managing
        // enablement by hand lets informational rows keep their real colour.
        menu.autoenablesItems = false
        statusItem.menu = menu

        state.onChange = { [weak self] in self?.updateButton() }
        updateButton()

        // NSMenu tracking is modal and runs the loop in .eventTracking, where a
        // timer scheduled the usual way never fires - which is why the readout
        // used to freeze the moment the menu opened.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // synchronous: a Task hop would not drain while a menu is tracking
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        timer = t
    }

    /// Opens the menu and writes its screen rect (top-left origin, points) to
    /// `path`, so a screenshot can be taken of exactly that region.
    ///
    /// The app pops its own menu rather than being driven from outside, which
    /// keeps this from needing accessibility automation.
    private var backdrop: NSWindow?

    /// A plain dark sheet behind the menu, so its translucency picks up an even
    /// backdrop instead of whatever happens to be on the desktop.
    private func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.backgroundColor = NSColor(calibratedRed: 0.051, green: 0.082, blue: 0.118, alpha: 1)
        w.level = .normal
        w.isOpaque = true
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        backdrop = w
    }

    func openMenuForCapture(frameFile path: String, holdFor seconds: TimeInterval) {
        showBackdrop()
        // menu tracking is modal, so the timers must be scheduled before the
        // click and run in the tracking mode
        let locate = Timer(timeInterval: 1.0, repeats: false) { _ in
            let menuWindow = NSApp.windows.first {
                $0.className.contains("Menu") && $0.isVisible
            }
            guard let w = menuWindow, let screen = NSScreen.screens.first else { return }
            let f = w.frame
            // AppKit is bottom-left origin; screencapture wants top-left
            let top = screen.frame.height - f.maxY
            let rect = "\(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
            try? rect.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let dismiss = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.statusItem.menu?.cancelTracking()
            NSApp.terminate(nil)
        }
        for t in [locate, dismiss] {
            RunLoop.main.add(t, forMode: .common)
            RunLoop.main.add(t, forMode: .eventTracking)
        }
        statusItem.button?.performClick(nil)
    }

    /// Same idea for the configuration window.
    func openConfigForCapture(frameFile path: String, holdFor seconds: TimeInterval) {
        openConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let w = self?.configWindow?.window, let screen = NSScreen.screens.first
            else { return }
            let f = w.frame
            let top = screen.frame.height - f.maxY
            let rect = "\(Int(f.origin.x)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
            try? rect.write(toFile: path, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.terminate(nil)
        }
    }

    private func poll() {
        tick += 1
        if menuOpen {
            // repaint the lines we already have; adding or removing items would
            // disturb a tracking menu. Readings come from the background
            // poller's cache, so this never waits on a socket.
            repaintOpenMenu()
        } else if tick % 2 == 0 {
            state.refresh()
        }
    }

    private func repaintOpenMenu() {
        for (id, item) in readingItems {
            guard let st = state.status[id] else { continue }
            if let reading = state.reading(id) {
                item.attributedTitle = Self.readingLine(reading)
            } else if st.running {
                item.attributedTitle = NSAttributedString(
                    string: "      reading\u{2026}",
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: Self.detailColor])
            }
        }
        updateButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        repaintOpenMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        readingItems.removeAll()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let name = state.anyRunning
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AB6A RigCtl")
        image?.isTemplate = !state.anyRunning
        button.image = image
        button.contentTintColor = state.anyRunning ? Self.accent : nil
        button.toolTip = state.anyRunning ? "AB6A RigCtl - daemons running" : "AB6A RigCtl"
    }

    /// Builds the menu once and describes it, without a status bar or run loop.
    /// Exercises the exact path that renders when the menu is clicked.
    func selfTest() -> [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map { item in
            let text = item.attributedTitle?.string ?? item.title
            let mark = item.isSeparatorItem ? "---" : (item.state == .on ? "[x]" : (item.isEnabled ? " . " : "   "))
            return "\(mark) \(text)"
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        state.refresh()
        menu.removeAllItems()
        readingItems.removeAll()

        if state.profiles.isEmpty {
            menu.addItem(info("No radios configured yet"))
            menu.addItem(info("Choose Configure below"))
        } else {
            for group in state.groupedProfiles {
                let first = group.profiles[0]
                var detail = ModelTable.name(for: first.model, kind: first.deviceKind)
                if first.deviceKind != .rig { detail += "  \u{00B7} \(first.deviceKind.displayName)" }
                menu.addItem(heading(group.radio, detail: detail))
                for p in group.profiles { addDaemon(p, to: menu) }
            }
        }

        let unconfigured = state.unconfiguredRadios
        if !unconfigured.isEmpty {
            menu.addItem(.separator())
            menu.addItem(info("Attached, not configured"))
            for r in unconfigured {
                let n = r.interfaces.count
                menu.addItem(info("   \(r.name) - \(n) interface\(n == 1 ? "" : "s")"))
            }
        }

        menu.addItem(.separator())

        let configure = NSMenuItem(title: "Configure\u{2026}",
                                   action: #selector(openConfig), keyEquivalent: ",")
        configure.target = self
        configure.isEnabled = true
        menu.addItem(configure)

        menu.addItem(.separator())

        let startAll = NSMenuItem(title: "Start all connected",
                                  action: #selector(startAll), keyEquivalent: "")
        startAll.target = self
        startAll.isEnabled = state.profiles.contains {
            state.status[$0.id]?.connected == true && state.status[$0.id]?.running != true
        }
        menu.addItem(startAll)

        let stopAll = NSMenuItem(title: "Stop all", action: #selector(stopAllDaemons),
                                 keyEquivalent: "")
        stopAll.target = self
        stopAll.isEnabled = state.anyRunning
        menu.addItem(stopAll)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About AB6A RigCtl\u{2026}",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.isEnabled = true
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit AB6A RigCtl", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private func addDaemon(_ p: Profile, to menu: NSMenu) {
        let st = state.status[p.id] ?? DaemonStatus()
        let title = NSMutableAttributedString(
            string: "   \(p.name)",
            attributes: [.font: NSFont.menuFont(ofSize: 13)])
        title.append(NSAttributedString(
            string: "   port \(p.port)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        let mi = NSMenuItem(title: "", action: #selector(toggleDaemon(_:)), keyEquivalent: "")
        mi.attributedTitle = title
        mi.target = self
        mi.representedObject = p.id
        mi.state = st.running ? .on : .off
        mi.isEnabled = st.connected && !state.busy.contains(p.id)
        menu.addItem(mi)

        if let reading = state.reading(p.id) {
            let item = info(attributed: Self.readingLine(reading))
            readingItems[p.id] = item          // updated in place while open
            menu.addItem(item)
        } else if st.running {
            // keep a slot so a reading can appear without rebuilding the menu
            let item = info("      reading\u{2026}")
            readingItems[p.id] = item
            menu.addItem(item)
        } else if !st.connected {
            menu.addItem(info("      not connected"))
        } else if let err = st.lastError {
            menu.addItem(info(attributed: NSAttributedString(
                string: "      \(err)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.systemRed])))
        }
    }

    static func readingLine(_ reading: RigClient.Reading) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "      \(reading.primary)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: frequencyColor])
        if !reading.secondary.isEmpty {
            line.append(NSAttributedString(
                string: "  \(reading.secondary)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: modeColor]))
        }
        return line
    }

    private func heading(_ text: String, detail: String) -> NSMenuItem {
        let s = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 13).bold,
                         .foregroundColor: Self.nameColor])
        s.append(NSAttributedString(
            string: "   \(detail)",
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: Self.detailColor]))
        return info(attributed: s)
    }

    private func info(_ text: String) -> NSMenuItem {
        info(attributed: NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
    }

    /// An informational row: no action, but left "enabled" so AppKit renders it
    /// at full contrast rather than dimming it.
    private func info(attributed: NSAttributedString) -> NSMenuItem {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = attributed
        mi.isEnabled = true
        return mi
    }

    // MARK: actions

    @objc private func toggleDaemon(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = state.profiles.first(where: { $0.id == id }) else { return }
        state.toggle(p)
    }

    private static let helpEmail = "AB6A.US@gmail.com"

    @objc private func showAbout() {
        let body = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString()

        credits.append(NSAttributedString(
            string: "Runs a Hamlib rigctld daemon for each of your radio's "
                  + "interfaces, so WSJT-X, fldigi and logging software have "
                  + "something to connect to.\n\n",
            attributes: [.font: body]))

        credits.append(NSAttributedString(
            string: "Help  ", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)]))
        credits.append(NSAttributedString(
            string: Self.helpEmail + "\n",
            attributes: [.font: body,
                         .link: URL(string: "mailto:\(Self.helpEmail)")!,
                         .foregroundColor: Self.accent]))

        credits.append(NSAttributedString(
            string: "Source  ", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)]))
        credits.append(NSAttributedString(
            string: "github.com/djsincla/ab6a-rigctl\n\n",
            attributes: [.font: body,
                         .link: URL(string: "https://github.com/djsincla/ab6a-rigctl")!,
                         .foregroundColor: Self.accent]))

        credits.append(NSAttributedString(
            string: "GPL-2.0-or-later, the licence Hamlib applies to its own "
                  + "programs. Hamlib is installed separately and licensed "
                  + "separately.",
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "ApplicationName"): "AB6A RigCtl",
        ])
    }

    @objc private func openConfig() {
        if configWindow == nil {
            configWindow = ConfigWindowController(state: state) { [weak self] in
                self?.state.refresh()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        configWindow?.showWindow(nil)
        configWindow?.window?.center()
        configWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func startAll() { state.startAllConnected() }
    @objc private func stopAllDaemons() { state.stopAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
