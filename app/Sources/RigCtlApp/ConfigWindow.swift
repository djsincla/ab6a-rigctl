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
        let existingID: String?
    }

    /// Titles offered for the VFO picker, and the value each stores.
    private static let vfos: [(title: String, value: String?)] = [
        ("current VFO", nil), ("Main", "Main"), ("Sub", "Sub"),
        ("VFO A", "VFOA"), ("VFO B", "VFOB"),
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
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        showAll = NSButton(checkboxWithTitle: "Show all serial devices, not just /dev/cu.usbmodem*",
                           target: self, action: #selector(toggleShowAll))
        showAll.state = state.showAllDevices ? .on : .off
        showAll.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(showAll)

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

        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        let root = NSStackView(views: [scroll, buttons])
        root.orientation = .vertical
        root.spacing = 8
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

        // fit the window to the content rather than leaving empty space
        content.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize.height + 60
        window.setContentSize(NSSize(width: 640, height: min(620, max(200, needed))))
    }

    /// Top-left origin, so scroll content starts at the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
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

        let path = label(iface.devicePath, size: 11, secondary: true)

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

        let line = NSStackView(views: [
            enable, path, NSView(),
            label("as", size: 11, secondary: true), name,
            label("reads", size: 11, secondary: true), vfo,
            label("TCP", size: 11, secondary: true), port,
        ])
        line.orientation = .horizontal
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)

        rows.append(IfaceRow(iface: iface, enable: enable, name: name, port: port,
                             vfo: vfo, existingID: existing?.id))
        return line
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

    /// Describes the built window without showing it - exercises the whole
    /// construction path that runs when the window is opened.
    func selfTest() -> [String] {
        var out: [String] = []
        out.append("show all serial devices: \(showAll.state == .on)")
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
                           + "  reads \(row.vfo.titleOfSelectedItem ?? "?")"
                           + "  TCP \(row.port.stringValue)")
            }
        }
        return out
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
                radio: .init(key: key, name: finalRadioName, serial: row.iface.serialNumber),
                model: modelID,
                baud: baud,
                port: port,
                civaddr: civ.isEmpty ? nil : civ,
                extraArgs: state.profiles.first { $0.id == row.existingID }?.extraArgs ?? [],
                device: .init(vid: row.iface.vendorID, pid: row.iface.productID,
                              serial: row.iface.serialNumber,
                              interfaceNumber: row.iface.interfaceNumber,
                              product: row.iface.productName, vendor: row.iface.vendorName,
                              dev: row.iface.devicePath)))
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

    private func alert(_ message: String, detail: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = .warning
        if let window { a.beginSheetModal(for: window, completionHandler: nil) }
    }
}
