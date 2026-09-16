import AppKit

/// "Configure" - name a device, choose its type, Hamlib model and baud rate,
/// then pick which of its interfaces carry a daemon and on which TCP port.
///
/// One row per interface. An interface either has a daemon or it does not;
/// there is no way to point two daemons at one interface, because an interface
/// is never shared.
@MainActor
final class ConfigWindowController: NSWindowController, NSWindowDelegate {

    private struct IfaceRow {
        let iface: Interface
        let enable: NSButton
        let name: NSTextField
        let port: NSTextField
        let vfo: NSPopUpButton
        let node: NSPopUpButton
        let extra: NSTextField
        let existingID: String?
    }

    /// Titles offered for the VFO picker, and the value each stores.
    /// Stored values stay as Hamlib's own names so existing configurations keep
    /// working; only what is shown changes.
    private static let vfos: [(title: String, value: String?)] = [
        ("current VFO", nil),
        ("A and B", RigClient.bothVFOs),
        ("VFO A", "Main"), ("VFO B", "Sub"),
    ]

    private struct RadioFields {
        let name: NSTextField
        let kind: NSPopUpButton
        let model: NSComboBox
        let baud: NSPopUpButton
        let civ: NSTextField
        let product: String?
        let hint: NSTextField
    }

    private static let bauds = [0, 4800, 9600, 19200, 38400, 57600, 115200]

    private let state: AppState
    private let onSave: () -> Void
    private var rows: [IfaceRow] = []
    private var radioFields: [String: RadioFields] = [:]
    private var showAll: NSButton!
    private var hamlibField: NSTextField!
    private var hamlibStatus: NSTextField!
    private var testButton: NSButton!
    private var sizingNote = ""
    private let testQueue = DispatchQueue(label: "rigctl.configtest")

    init(state: AppState, onSave: @escaping () -> Void) {
        self.state = state
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AB6A RigCtl - Devices"
        super.init(window: window)
        window.delegate = self
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func rebuild() {
        guard let window else { return }
        state.refresh()
        rows.removeAll()
        radioFields.removeAll()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        showAll = NSButton(checkboxWithTitle: "Show all serial devices, not just /dev/cu.usbmodem*",
                           target: self, action: #selector(toggleShowAll))
        showAll.state = state.showAllDevices ? .on : .off
        showAll.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(showAll)
        stack.addArrangedSubview(hamlibRow())

        let radios = state.selectableRadios
        if radios.isEmpty {
            stack.addArrangedSubview(label("No devices found.", size: 13))
            stack.addArrangedSubview(
                label("Only /dev/cu.usbmodem* devices are shown by default. A radio on a "
                      + "USB-serial adapter appears once you tick the box above.",
                      size: 11, secondary: true))
        }
        for radio in radios { stack.addArrangedSubview(section(for: radio)) }

        // Configured devices that are not attached have no rows to untick, so
        // without this they could never be removed from here at all.
        let visible = Set(radios.map { $0.key })
        var absentSeen = Set<String>()
        var absent: [(key: String, name: String, profiles: [Profile])] = []
        for p in state.profiles {
            guard let key = p.radio?.key, !visible.contains(key),
                  !absentSeen.contains(key) else { continue }
            absentSeen.insert(key)
            absent.append((key, p.radioName,
                           state.profiles.filter { $0.radio?.key == key }))
        }
        if !absent.isEmpty {
            stack.addArrangedSubview(label("Configured, not attached", size: 11, secondary: true))
            for entry in absent {
                let name = label(entry.name, size: 13)
                name.font = .systemFont(ofSize: 13, weight: .semibold)
                let ports = entry.profiles.map { "\($0.name) \u{00B7} \($0.port)" }
                    .joined(separator: ",  ")
                let row = NSStackView(views: [
                    name, label(ports, size: 11, secondary: true),
                    removeButton(key: entry.key, name: entry.name),
                ])
                row.orientation = .horizontal
                row.spacing = 10
                stack.addArrangedSubview(row)
            }
        }

        // AppKit anchors an unflipped document view at the bottom, which leaves
        // short content sitting under a gap. A flipped container pins it to the top.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        testButton = NSButton(title: "Test", target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        testButton.toolTip = "Run the daemon with these settings and see whether the rig answers"

        let buttons = NSStackView(views: [testButton, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)

        // The scroll view gives up space, never the button row. Required
        // *hugging* on the row would be wrong: NSStackView's fittingSize leaves
        // its own insets out, so hugging it tightly squashes them away - which
        // is what put the buttons against the window edge.
        buttons.setContentCompressionResistancePriority(.required, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let root = NSStackView(views: [scroll, buttons])
        root.orientation = .vertical
        root.spacing = 8
        // the bottom margin lives here, where nothing can collapse it
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            // the clip view drives the document's width and top; the stack
            // drives its height
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        window.contentView = content

        // Fit the window to its content, in both directions. The interface rows
        // are wider than any fixed width worth choosing, and pinning the window
        // narrower than them pushed text against the edge.
        content.layoutSubtreeIfNeeded()
        // Measure the button row rather than guessing at its height: a guess
        // that falls short gets taken out of its bottom inset, leaving the
        // buttons against the window edge.
        let contentFit = stack.fittingSize
        // fittingSize leaves the stack's own insets out, so add them back
        let buttonFit = buttons.fittingSize
        let rowHeight = max(buttonFit.height, 32)
        let chrome = rowHeight + root.spacing + root.edgeInsets.bottom + 8
        let finalHeight = min(760, max(240, contentFit.height + chrome))
        window.setContentSize(NSSize(
            width: min(1200, max(680, contentFit.width + 20)),   // room for the scroller
            height: finalHeight))
        sizingNote = "content \(Int(contentFit.height))  buttons \(Int(buttonFit.height))"
            + "  chrome \(Int(chrome))  window \(Int(finalHeight))"
            + "  root \(Int(root.fittingSize.height))"
    }

    /// Top-left origin, so scroll content starts at the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Where Hamlib lives. Normally blank - it is found automatically - but a
    /// machine with Hamlib somewhere unusual, or with a broken copy shadowing a
    /// good one, needs to be able to say.
    private func hamlibRow() -> NSView {
        hamlibField = NSTextField(string: Store.hamlibDir ?? "")
        hamlibField.placeholderString = "found automatically - set only if that fails"
        hamlibField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hamlibField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hamlibField.target = self
        hamlibField.action = #selector(hamlibChanged)

        let choose = NSButton(title: "Choose\u{2026}", target: self,
                              action: #selector(chooseHamlib))
        choose.bezelStyle = .rounded
        choose.controlSize = .small

        hamlibStatus = label("", size: 11, secondary: true)
        updateHamlibStatus()

        let row = NSStackView(views: [
            label("Hamlib", size: 11, secondary: true), hamlibField, choose, hamlibStatus,
        ])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func updateHamlibStatus() {
        Hamlib.forget()
        if let v = Hamlib.version {
            hamlibStatus.stringValue = "found \(v)"
            hamlibStatus.textColor = .secondaryLabelColor
        } else {
            hamlibStatus.stringValue = "not found - daemons cannot start"
            hamlibStatus.textColor = .systemRed
        }
    }

    @objc private func hamlibChanged() {
        Store.hamlibDir = hamlibField.stringValue.trimmingCharacters(in: .whitespaces)
        updateHamlibStatus()
    }

    @objc private func chooseHamlib() {
        let panel = NSOpenPanel()
        panel.title = "Where is Hamlib installed?"
        panel.message = "Choose the folder holding rigctl and rigctld, usually a bin directory."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            self.hamlibField.stringValue = url.path
            self.hamlibChanged()
        }
    }

    @objc private func toggleShowAll() {
        state.showAllDevices = showAll.state == .on
        rebuild()
    }

    private func section(for radio: Radio) -> NSView {
        let existing = state.profiles.first { $0.radio?.key == radio.key }
        let first = radio.interfaces.first

        // A generic USB-serial bridge reports itself, not the radio behind it,
        // so the name is editable rather than fixed to the descriptor.
        let name = NSTextField(string: existing?.radioName ?? radio.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true

        var headBits: [NSView] = [label("Device", size: 11, secondary: true), name]
        if let serial = radio.serialNumber {
            headBits.append(label("serial \(serial)", size: 11, secondary: true))
        } else if let path = first?.devicePath {
            headBits.append(label(path, size: 11, secondary: true))
        }
        if existing != nil {
            headBits.append(removeButton(key: radio.key, name: radio.name))
        }
        let header = NSStackView(views: headBits)
        header.orientation = .horizontal
        header.spacing = 8

        // transceiver, rotator or amplifier - each has its own Hamlib daemon,
        // model table and default port
        let kindPicker = NSPopUpButton()
        kindPicker.addItems(withTitles: DeviceKind.allCases.map { $0.displayName })
        kindPicker.identifier = NSUserInterfaceItemIdentifier(radio.key)
        kindPicker.target = self
        kindPicker.action = #selector(kindChanged(_:))
        let currentKind = existing?.deviceKind ?? .rig
        kindPicker.selectItem(at: DeviceKind.allCases.firstIndex(of: currentKind) ?? 0)

        let combo = NSComboBox()
        combo.usesDataSource = false
        combo.completes = true
        combo.numberOfVisibleItems = 12
        combo.widthAnchor.constraint(equalToConstant: 260).isActive = true
        populate(combo, kind: currentKind, product: first?.productName,
                 selecting: existing?.model)

        let baud = NSPopUpButton()
        baud.addItems(withTitles: Self.bauds.map { $0 == 0 ? "rig default" : String($0) })
        if let b = existing?.baud, let idx = Self.bauds.firstIndex(of: b) {
            baud.selectItem(at: idx)
        }

        let civ = NSTextField(string: existing?.civaddr ?? "")
        civ.placeholderString = "auto"
        civ.widthAnchor.constraint(equalToConstant: 60).isActive = true
        civ.font = .systemFont(ofSize: 12)

        let settings = NSStackView(views: [
            label("Type", size: 11, secondary: true), kindPicker,
            label("Model", size: 11, secondary: true), combo,
        ])
        settings.orientation = .horizontal
        settings.spacing = 8

        let serial = NSStackView(views: [
            label("Baud", size: 11, secondary: true), baud,
            label("CI-V", size: 11, secondary: true), civ,
        ])
        serial.orientation = .horizontal
        serial.spacing = 8

        let hint = label(hintText(kind: currentKind, product: first?.productName),
                         size: 10, secondary: true)
        radioFields[radio.key] = RadioFields(name: name, kind: kindPicker, model: combo,
                                             baud: baud, civ: civ,
                                             product: first?.productName, hint: hint)
        var views: [NSView] = [header, settings, serial, hint]
        for iface in radio.interfaces { views.append(interfaceRow(radio: radio, iface: iface)) }
        return column(views)
    }

    /// Fill the model box for a kind: suggestions first, then that kind's table.
    private func populate(_ combo: NSComboBox, kind: DeviceKind,
                          product: String?, selecting model: Int?) {
        let suggested = ModelTable.suggestions(forProduct: product, kind: kind)
        let suggestedIDs = Set(suggested.map { $0.id })
        combo.removeAllItems()
        combo.addItems(withObjectValues:
            suggested.map { $0.listing }
            + ModelTable.all(kind).filter { !suggestedIDs.contains($0.id) }.map { $0.listing })
        switch kind {
        case .rig: combo.placeholderString = "type a model, e.g. IC-7300"
        case .rotator: combo.placeholderString = "type a model, e.g. GS-232"
        case .amplifier: combo.placeholderString = "type a model, e.g. KPA1500"
        }
        if let model, let m = ModelTable.model(withID: model, kind: kind) {
            combo.stringValue = m.listing
        } else if let guess = suggested.first {
            combo.stringValue = guess.listing
        } else {
            combo.stringValue = ""
        }
    }

    private func hintText(kind: DeviceKind, product: String?) -> String {
        if ModelTable.suggestions(forProduct: product, kind: kind).isEmpty {
            return "This adapter does not identify the device - choose the model yourself."
        }
        return "Runs \(kind.daemon); default port \(kind.defaultPort)."
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue, let f = radioFields[key] else { return }
        let kind = DeviceKind.allCases[sender.indexOfSelectedItem]
        populate(f.model, kind: kind, product: f.product, selecting: nil)
        f.hint.stringValue = hintText(kind: kind, product: f.product)
        // serial settings only mean something for a transceiver
        f.civ.isEnabled = kind == .rig
        // re-seed ports from this kind's default
        for row in rows where row.iface.radioKey == key {
            row.port.stringValue = String(nextFreePort(for: kind, excluding: row.port))
            row.vfo.isEnabled = kind == .rig
            if kind != .rig { row.vfo.selectItem(at: 0) }
        }
    }

    private func removeButton(key: String, name: String) -> NSButton {
        let b = NSButton(title: "\u{2715}", target: self, action: #selector(removeTapped(_:)))
        b.bezelStyle = .circular
        b.controlSize = .small
        b.font = .systemFont(ofSize: 10)
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.toolTip = "Remove \(name) and every daemon configured for it"
        return b
    }

    /// Deleting is immediate rather than deferred to Save: a device that is not
    /// attached has no row to untick, so there would be nothing for Save to act
    /// on.
    @objc private func removeTapped(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let doomed = state.profiles.filter { p in
            if p.radio?.key == key { return true }
            // also anything bound to this physical device's interfaces
            if let radio = state.radios.first(where: { $0.key == key }) {
                return p.match(in: radio.interfaces) != nil
            }
            return false
        }
        guard !doomed.isEmpty, let window else { return }

        let names = doomed.map { $0.fullName }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = doomed.count == 1
            ? "Remove \(doomed[0].fullName)?"
            : "Remove \(doomed.count) daemons?"
        alert.informativeText = doomed.count == 1
            ? "Its daemon will be stopped and the configuration deleted."
            : "\(names) will be stopped and their configuration deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for p in doomed { Daemons.stop(p) }
            let keep = self.state.profiles.filter { kept in
                !doomed.contains { $0.id == kept.id }
            }
            try? Store.save(keep)
            self.onSave()
            self.rebuild()
        }
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let box = NSStackView(views: views)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 9
        return box
    }

    private func interfaceRow(radio: Radio, iface: Interface) -> NSView {
        let existing = state.profiles.first { $0.match(in: [iface]) != nil }

        let enable = NSButton(checkboxWithTitle: iface.label, target: nil, action: nil)
        enable.state = existing != nil ? .on : .off
        enable.font = .systemFont(ofSize: 12)

        // With the full list showing, name the dial-in twin too: macOS exposes
        // every port as both cu.* and tty.*, and a port is often known by its
        // tty.* name elsewhere, so people look for it here and do not find it.
        // The daemons are always given the cu.* node.
        var pathText = iface.devicePath
        if state.showAllDevices, let dialin = iface.dialinPath {
            pathText += "   (\(dialin))"
        }
        let path = label(pathText, size: 11, secondary: true)

        let name = NSTextField(string: existing?.name ?? defaultName(for: iface, on: radio))
        name.placeholderString = "what will use it"
        name.widthAnchor.constraint(equalToConstant: 130).isActive = true
        name.font = .systemFont(ofSize: 12)

        let kindForPort = existing?.deviceKind
            ?? (radioFields[radio.key].map { DeviceKind.allCases[$0.kind.indexOfSelectedItem] } ?? .rig)
        let port = NSTextField(string: String(existing?.port ?? nextFreePort(for: kindForPort)))
        port.widthAnchor.constraint(equalToConstant: 62).isActive = true
        port.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.maximum = 65535
        port.formatter = fmt

        // Which receiver this daemon reports. Plain get_freq follows whatever
        // VFO the rig currently has selected, so two daemons on one radio
        // otherwise show the same frequency.
        let vfo = NSPopUpButton()
        vfo.addItems(withTitles: Self.vfos.map { $0.title })
        if let want = existing?.vfo,
           let idx = Self.vfos.firstIndex(where: { $0.value == want }) {
            vfo.selectItem(at: idx)
        }
        vfo.isEnabled = (existing?.deviceKind ?? .rig) == .rig

        // macOS creates two nodes for every serial port. cu.* is the sensible
        // default - it opens immediately, where tty.* waits on carrier detect -
        // but some setups are built around the tty.* name, so let it be chosen.
        let node = NSPopUpButton()
        node.addItems(withTitles: ["cu", "tty"])
        if existing?.node == "tty" { node.selectItem(at: 1) }
        node.isEnabled = iface.dialinPath != nil
        node.toolTip = iface.dialinPath.map {
            "call-out \(iface.devicePath)\ndial-in  \($0)"
        } ?? "only a call-out node exists for this port"

        let line = NSStackView(views: [
            enable, path, node, NSView(),
            label("as", size: 11, secondary: true), name,
            label("reads", size: 11, secondary: true), vfo,
            label("TCP", size: 11, secondary: true), port,
        ])
        line.orientation = .horizontal
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)

        // anything else to hand the daemon, passed through verbatim:
        // -C timeout=500, -P RIG, --vfo, and so on
        let extra = NSTextField(string: (existing?.extraArgs ?? []).joined(separator: " "))
        extra.placeholderString = "extra daemon options, e.g. -C timeout=500 -C retry=0"
        extra.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let extraLine = NSStackView(views: [
            label("options", size: 11, secondary: true), extra,
        ])
        extraLine.orientation = .horizontal
        extraLine.spacing = 8
        extraLine.edgeInsets = NSEdgeInsets(top: 0, left: 32, bottom: 0, right: 0)
        extra.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let block = NSStackView(views: [line, extraLine])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4

        rows.append(IfaceRow(iface: iface, enable: enable, name: name, port: port,
                             vfo: vfo, node: node, extra: extra, existingID: existing?.id))
        return block
    }

    private func defaultName(for iface: Interface, on radio: Radio) -> String {
        radio.interfaces.count == 1 ? "main" : (iface.interfaceNumber.map { "port \($0)" } ?? "main")
    }

    /// Next free port for a kind, starting at Hamlib's default for it and
    /// stepping over the ports the other kinds expect, so adding a second radio
    /// never claims the port a rotator will want.
    private func nextFreePort(for kind: DeviceKind = .rig,
                              excluding field: NSTextField? = nil) -> Int {
        var taken = Set(state.profiles.map { $0.port })
        for r in rows where r.port !== field {
            if let p = Int(r.port.stringValue) { taken.insert(p) }
        }
        let reserved = DeviceKind.reservedPorts.subtracting([kind.defaultPort])
        var port = kind.defaultPort
        while taken.contains(port) || reserved.contains(port) { port += 1 }
        return port
    }

    private func label(_ text: String, size: CGFloat, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size)
        if secondary { l.textColor = .secondaryLabelColor }
        l.lineBreakMode = .byWordWrapping
        return l
    }

    /// Ticks every interface, sets the node picker, and saves - exercising the
    /// real save path rather than a description of it.
    func selfTestSave(nodeIndex: Int) -> [String] {
        for row in rows {
            row.enable.state = .on
            if row.node.isEnabled { row.node.selectItem(at: nodeIndex) }
        }
        saveTapped()
        return Store.load().map {
            "\($0.fullName): node=\($0.node ?? "nil")  dev=\($0.device.dev ?? "nil")"
        }
    }

    /// Describes the built window without showing it - exercises the whole
    /// construction path that runs when the window is opened.
    func selfTest() -> [String] {
        var out: [String] = []
        out.append("show all serial devices: \(showAll.state == .on)")
        out.append("sizing: \(sizingNote)")
        out.append("discovery: \(state.radios.count) devices, selectable: \(state.selectableRadios.count), fields: \(radioFields.count)")
        for r in state.radios {
            out.append("   seen: \(r.name)  \(r.interfaces.map { $0.devicePath }.joined(separator: " "))")
        }
        for radio in state.selectableRadios {
            guard let f = radioFields[radio.key] else { continue }
            out.append("\(f.name.stringValue)")
            out.append("   model   \(f.model.stringValue.isEmpty ? "(none - pick one)" : f.model.stringValue)")
            out.append("   choices \(f.model.numberOfItems) models, baud \(f.baud.titleOfSelectedItem ?? "?")")
            for row in rows where row.iface.radioKey == radio.key {
                out.append("   [\(row.enable.state == .on ? "x" : " ")] \(row.enable.title)"
                           + "  \(row.iface.devicePath)"
                           + "  as \(row.name.stringValue)"
                           + "  node \(row.node.titleOfSelectedItem ?? "?")"
                           + "  reads \(row.vfo.titleOfSelectedItem ?? "?")"
                           + "  TCP \(row.port.stringValue)")
            }
        }
        return out
    }

    // MARK: test

    /// Runs each ticked interface for real, using the values currently in the
    /// fields rather than what is saved, on a scratch port so a daemon already
    /// running on the configured port is left alone.
    @objc private func testTapped() {
        let jobs: [(String, [String])] = rows.compactMap { rigctlJob(for: $0) }

        guard !jobs.isEmpty else {
            alert("Nothing to test.", detail: "Tick an interface first.")
            return
        }

        // rigctl opens the serial port itself, so a daemon holding it would make
        // the answers meaningless
        let busy = state.profiles.filter { Daemons.runningPID($0) != nil }
        if !busy.isEmpty {
            let names = busy.map { $0.fullName }.joined(separator: ", ")
            let a = NSAlert()
            a.messageText = "Stop the running daemon first?"
            a.informativeText = "rigctl talks to the radio directly, so it cannot share the "
                + "serial port with \(names). Testing while it runs gives unreliable answers."
            a.addButton(withTitle: "Stop and test")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window!) { [weak self] r in
                guard r == .alertFirstButtonReturn else { return }
                for p in busy { Daemons.stop(p) }
                self?.runTests(jobs)
            }
            return
        }
        runTests(jobs)
    }

    private func runTests(_ jobs: [(String, [String])]) {

        testButton.isEnabled = false
        testButton.title = "Testing\u{2026}"
        testQueue.async { [weak self] in
            var lines: [String] = []
            var allGood = true
            for (name, cmd) in jobs {
                if cmd.isEmpty {
                    lines.append("\(name): no valid model chosen")
                    allGood = false
                    continue
                }
                let (ok, detail) = Self.tryRigctl(cmd)
                lines.append("\(name): \(detail)")
                if !ok { allGood = false }
            }
            DispatchQueue.main.async {
                self?.testButton.isEnabled = true
                self?.testButton.title = "Test"
                self?.alert(allGood ? "Everything answered." : "Something did not work.",
                            detail: lines.joined(separator: "\n\n"),
                            style: allGood ? .informational : .warning)
            }
        }
    }

    /// The rigctl command line for one ticked interface, from the fields as they
    /// stand rather than from what is saved.
    private func rigctlJob(for row: IfaceRow) -> (String, [String])? {
        guard row.enable.state == .on else { return nil }
        guard let fields = radioFields[row.iface.radioKey] else { return nil }
        let kind = DeviceKind.allCases[fields.kind.indexOfSelectedItem]
        guard let model = ModelTable.id(fromListing: fields.model.stringValue, kind: kind) else {
            return (row.enable.title, [])          // reported as "no valid model"
        }

        let useDialin = row.node.indexOfSelectedItem == 1
        let fallback: String = row.iface.devicePath
        let path: String = useDialin ? (row.iface.dialinPath ?? fallback) : fallback

        var cmd: [String] = [Hamlib.tool(kind.lister), "-m", String(model), "-r", path]
        let baudIndex = fields.baud.indexOfSelectedItem
        if baudIndex > 0 {
            cmd.append("-s")
            cmd.append(String(Self.bauds[baudIndex]))
        }
        let civ = fields.civ.stringValue.trimmingCharacters(in: .whitespaces)
        if kind == .rig && !civ.isEmpty {
            cmd.append("-c")
            cmd.append(civ)
        }
        let rawExtra: String = row.extra.stringValue
        let pieces: [String] = rawExtra.components(separatedBy: CharacterSet.whitespaces)
        for piece in pieces where !piece.isEmpty {
            cmd.append(piece)
        }
        return (row.enable.title, cmd)
    }

    /// Ask the rig directly with rigctl - no daemon, no TCP port.
    ///
    /// This is the honest test of a configuration: rigctl opens the serial
    /// device itself with the model and baud rate given, so a wrong model or
    /// the wrong port shows up immediately rather than as a daemon that starts
    /// and then never answers.
    private nonisolated static func tryRigctl(_ argv: [String]) -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv + ["f", "m"]
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            return (false, "could not run rigctl: \(error.localizedDescription)")
        }

        // rigctl can sit on a silent serial port; do not wait forever
        let deadline = Date().addingTimeInterval(8)
        while proc.isRunning && Date() < deadline { usleep(120_000) }
        if proc.isRunning {
            proc.terminate()
            return (false, "rigctl did not answer within 8 seconds\n   " + argv.joined(separator: " "))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = raw.split(separator: "\n").map(String.init)

        if proc.terminationStatus != 0 {
            let why = lines.last ?? "exit status \(proc.terminationStatus)"
            return (false, why + "\n   " + argv.joined(separator: " "))
        }
        guard let first = lines.first, Double(first) != nil else {
            return (false, (raw.isEmpty ? "no reply" : raw)
                         + "\n   " + argv.joined(separator: " "))
        }
        let mode = lines.count > 1 ? lines[1] : ""
        let hz = RigClient.frequencyText(Double(first) ?? 0)
        return (true, "working - \(hz) MHz \(mode)")
    }

    // MARK: save

    @objc private func cancelTapped() { close() }

    @objc private func saveTapped() {
        var seenPorts: [Int: String] = [:]
        var built: [Profile] = []

        for row in rows where row.enable.state == .on {
            let key = row.iface.radioKey
            guard let fields = radioFields[key] else { continue }

            let kind = DeviceKind.allCases[fields.kind.indexOfSelectedItem]
            guard let modelID = ModelTable.id(fromListing: fields.model.stringValue,
                                              kind: kind) else {
                alert("Choose a radio type for \(fields.name.stringValue).",
                      detail: fields.model.stringValue.isEmpty
                        ? "Nothing on a USB-serial adapter says which device is behind it, so the model has to be set by hand. Type a model name, or a Hamlib model number from the \(kind.lister) table."
                        : "\"\(fields.model.stringValue)\" is not in the Hamlib \(kind.displayName.lowercased()) table. Type a model name or number.")
                return
            }
            guard let port = Int(row.port.stringValue), (1...65535).contains(port) else {
                alert("\(row.enable.title): TCP port must be a number from 1 to 65535.")
                return
            }
            if let other = seenPorts[port] {
                alert("Two daemons cannot share TCP port \(port).",
                      detail: "\(other) already uses it. Give each daemon its own port.")
                return
            }
            seenPorts[port] = row.enable.title

            let radioName = fields.name.stringValue.trimmingCharacters(in: .whitespaces)
            let finalRadioName = radioName.isEmpty ? row.iface.radioName : radioName
            let ifaceName = row.name.stringValue.trimmingCharacters(in: .whitespaces)
            let finalIfaceName = ifaceName.isEmpty ? row.enable.title : ifaceName
            let baudIndex = fields.baud.indexOfSelectedItem
            let baud = baudIndex > 0 ? Self.bauds[baudIndex] : nil
            let civ = fields.civ.stringValue.trimmingCharacters(in: .whitespaces)

            built.append(Profile(
                id: row.existingID ?? slug("\(finalRadioName)-\(finalIfaceName)", existing: built),
                name: finalIfaceName,
                kind: kind.rawValue,
                vfo: kind == .rig ? Self.vfos[row.vfo.indexOfSelectedItem].value : nil,
                node: row.node.indexOfSelectedItem == 1 ? "tty" : "cu",
                radio: .init(key: key, name: finalRadioName, serial: row.iface.serialNumber),
                model: modelID,
                baud: baud,
                port: port,
                civaddr: civ.isEmpty ? nil : civ,
                extraArgs: row.extra.stringValue
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init),
                device: .init(vid: row.iface.vendorID, pid: row.iface.productID,
                              serial: row.iface.serialNumber,
                              interfaceNumber: row.iface.interfaceNumber,
                              product: row.iface.productName, vendor: row.iface.vendorName,
                              dev: row.node.indexOfSelectedItem == 1
                                  ? (row.iface.dialinPath ?? row.iface.devicePath)
                                  : row.iface.devicePath)))
        }

        // radios that are not attached right now keep their profiles untouched
        let visible = Set(state.selectableRadios.map { $0.key })
        let untouched = state.profiles.filter { !visible.contains($0.radio?.key ?? "") }

        // anything switched off has its daemon stopped before it disappears
        let kept = Set(built.map { $0.id } + untouched.map { $0.id })
        for p in state.profiles where !kept.contains(p.id) { Daemons.stop(p) }

        do {
            try Store.save(untouched + built)
        } catch {
            alert("Could not save.", detail: error.localizedDescription)
            return
        }
        onSave()
        close()
    }

    private func slug(_ text: String, existing: [Profile]) -> String {
        var base = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { base.append(ch) }
            else if !base.isEmpty && !base.hasSuffix("-") { base.append("-") }
        }
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty { base = "rig" }
        var candidate = base
        var n = 2
        let taken = Set(state.profiles.map { $0.id } + existing.map { $0.id })
        while taken.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
        return candidate
    }

    private func alert(_ message: String, detail: String = "",
                       style: NSAlert.Style = .warning) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = style
        if let window { a.beginSheetModal(for: window, completionHandler: nil) }
    }
}
