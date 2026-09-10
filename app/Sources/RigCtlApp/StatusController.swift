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

    /// The amber of the app icon's radiating arcs.
    private static let accent = NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.13, alpha: 1)

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        state.onChange = { [weak self] in self?.updateButton() }
        updateButton()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.state.refresh() }
        }
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

        if state.profiles.isEmpty {
            menu.addItem(info("No radios configured yet"))
            menu.addItem(info("Choose Configure radios below"))
        } else {
            for group in state.groupedProfiles {
                menu.addItem(heading(group.radio,
                                     detail: ModelTable.name(for: group.profiles[0].model)))
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

        let configure = NSMenuItem(title: "Configure radios\u{2026}",
                                   action: #selector(openConfig), keyEquivalent: ",")
        configure.target = self
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
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit AB6A RigCtl", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
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

        if let reading = st.reading {
            let line = NSMutableAttributedString(
                string: "      \(reading.frequencyText) MHz",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: Self.accent])
            if !reading.mode.isEmpty {
                line.append(NSAttributedString(
                    string: "  \(reading.mode)",
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
            }
            menu.addItem(info(attributed: line))
        } else if !st.connected {
            menu.addItem(info("      not connected"))
        } else if let err = st.lastError {
            menu.addItem(info(attributed: NSAttributedString(
                string: "      \(err)",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: NSColor.systemRed])))
        }
    }

    private func heading(_ text: String, detail: String) -> NSMenuItem {
        let s = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 13).bold])
        s.append(NSAttributedString(
            string: "   \(detail)",
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return info(attributed: s)
    }

    private func info(_ text: String) -> NSMenuItem {
        info(attributed: NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
    }

    private func info(attributed: NSAttributedString) -> NSMenuItem {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = attributed
        mi.isEnabled = false
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
