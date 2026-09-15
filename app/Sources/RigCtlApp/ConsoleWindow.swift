import AppKit

/// A console onto a running daemon: type a command, see the raw reply.
///
/// When a setup misbehaves the useful question is what the daemon actually
/// answers, not what the menu makes of it. This shows the exchange verbatim,
/// with timings, so it can be pasted into a support message.
@MainActor
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState
    private var target: NSPopUpButton!
    private var input: NSTextField!
    private var output: NSTextView!
    private let queue = DispatchQueue(label: "rigctl.console")

    /// Commands worth having one click away when helping someone.
    private static let presets: [(String, String)] = [
        ("f", "frequency"),
        ("m", "mode"),
        ("t", "PTT - 1 while transmitting"),
        ("s", "split, and which VFO transmits"),
        ("l STRENGTH", "S-meter, in dB relative to S9 - proves the receive path works"),
        ("\\get_rig_info", "every VFO, split and mode in one reply"),
        ("\\get_vfo_list", "which VFOs this backend believes the rig has"),
        ("\\chk_vfo", "is the daemon in VFO mode? clients behave differently if so"),
        ("\\dump_state", "what a client negotiates on connect"),
        ("\\dump_caps", "everything the backend claims the rig can do"),
    ]

    init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AB6A RigCtl - Console"
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        state.refresh()

        target = NSPopUpButton()
        refreshTargets()

        input = NSTextField()
        input.placeholderString = "a rigctl command, e.g. f   m   \\get_rig_info"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.target = self
        input.action = #selector(sendCommand)

        let sendButton = NSButton(title: "Send", target: self, action: #selector(sendCommand))
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded

        let top = NSStackView(views: [
            label("daemon"), target, input, sendButton,
        ])
        top.orientation = .horizontal
        top.spacing = 8
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func presetButton(_ cmd: String, _ why: String) -> NSButton {
            let b = NSButton(title: cmd, target: self, action: #selector(preset(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            b.toolTip = why          // hover says what each one is for
            return b
        }
        let half = (Self.presets.count + 1) / 2
        let rowOne = NSStackView(views: [label("try")]
            + Self.presets.prefix(half).map { presetButton($0.0, $0.1) })
        let rowTwo = NSStackView(views: [label("   ")]
            + Self.presets.dropFirst(half).map { presetButton($0.0, $0.1) })
        for r in [rowOne, rowTwo] { r.orientation = .horizontal; r.spacing = 5 }
        let presetRow = NSStackView(views: [rowOne, rowTwo])
        presetRow.orientation = .vertical
        presetRow.alignment = .leading
        presetRow.spacing = 4

        output = NSTextView()
        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = output
        scroll.borderType = .bezelBorder

        let copy = NSButton(title: "Copy all", target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded
        let bottom = NSStackView(views: [NSView(), copy, clear])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        let root = NSStackView(views: [top, presetRow, scroll, bottom])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        write("AB6A RigCtl console\n")
        write(Hamlib.banner + "\n")
        write("Type a command and press return. Replies are shown verbatim.\n\n")
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func refreshTargets() {
        target.removeAllItems()
        for p in state.profiles {
            let running = state.status[p.id]?.running == true
            target.addItem(withTitle: "\(p.fullName)  :\(p.port)\(running ? "" : "  (stopped)")")
            target.lastItem?.representedObject = p.port
        }
        if state.profiles.isEmpty {
            target.addItem(withTitle: "no daemons configured")
        }
    }

    // MARK: sending

    @objc private func preset(_ sender: NSButton) {
        input.stringValue = sender.title
        sendCommand()
    }

    @objc private func sendCommand() {
        let cmd = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty,
              let port = target.selectedItem?.representedObject as? Int else { return }
        input.stringValue = ""
        write("> \(cmd)\n")

        queue.async { [weak self] in
            let started = Date()
            let reply = Self.exchange(port: port, command: cmd)
            let ms = Date().timeIntervalSince(started) * 1000
            Task { @MainActor in
                self?.write(reply.isEmpty ? "(no reply)\n" : reply + "\n")
                self?.write(String(format: "  %.0f ms\n\n", ms))
            }
        }
    }

    /// One command, one connection - the daemon is stateless per exchange here,
    /// which keeps a console session from disturbing anything else.
    private nonisolated static func exchange(port: Int, command: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "cannot create socket" }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return "could not connect to localhost:\(port) - is the daemon running?" }

        let out = Array((command + "\n").utf8)
        _ = out.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // read until the daemon goes quiet; dump_caps is long
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if n < buf.count { break }
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: output

    private func write(_ s: String) {
        output.textStorage?.append(NSAttributedString(
            string: s,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        output.scrollToEndOfDocument(nil)
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.string, forType: .string)
    }

    @objc private func clear() {
        output.string = ""
    }
}
