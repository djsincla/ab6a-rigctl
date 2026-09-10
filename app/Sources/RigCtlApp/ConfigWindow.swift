import AppKit

/// "Configure radios" - name a radio, choose its Hamlib model and baud rate,
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
        let existingID: String?
    }

    private struct RadioFields {
        let name: NSTextField
        let model: NSComboBox
        let baud: NSPopUpButton
        let civ: NSTextField
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
        window.title = "AB6A RigCtl - Radios"
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
            stack.addArrangedSubview(label("No radios found.", size: 13))
            stack.addArrangedSubview(
                label("Only /dev/cu.usbmodem* devices are shown by default. A radio on a "
                      + "USB-serial adapter appears once you tick the box above.",
                      size: 11, secondary: true))
        }
        for radio in radios { stack.addArrangedSubview(section(for: radio)) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false

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
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2),
        ])
        window.contentView = content
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

        var headBits: [NSView] = [label("Radio", size: 11, secondary: true), name]
        if let serial = radio.serialNumber {
            headBits.append(label("serial \(serial)", size: 11, secondary: true))
        } else if let path = first?.devicePath {
            headBits.append(label(path, size: 11, secondary: true))
        }
        let header = NSStackView(views: headBits)
        header.orientation = .horizontal
        header.spacing = 8

        // model - suggestions first, then the whole Hamlib table
        let combo = NSComboBox()
        combo.usesDataSource = false
        combo.completes = true
        combo.numberOfVisibleItems = 12
        let suggested = ModelTable.suggestions(forProduct: first?.productName)
        let suggestedIDs = Set(suggested.map { $0.id })
        combo.addItems(withObjectValues:
            suggested.map { $0.listing }
            + ModelTable.all.filter { !suggestedIDs.contains($0.id) }.map { $0.listing })
        combo.widthAnchor.constraint(equalToConstant: 290).isActive = true
        combo.placeholderString = "type a model, e.g. IC-7300"

        if let existing, let m = ModelTable.model(withID: existing.model) {
            combo.stringValue = m.listing
        } else if let guess = suggested.first {
            combo.stringValue = guess.listing
        }

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
            label("Model", size: 11, secondary: true), combo,
            label("Baud", size: 11, secondary: true), baud,
            label("CI-V", size: 11, secondary: true), civ,
        ])
        settings.orientation = .horizontal
        settings.spacing = 8

        if suggested.isEmpty {
            let hint = label("This adapter does not identify the radio - choose the model yourself.",
                             size: 10, secondary: true)
            radioFields[radio.key] = RadioFields(name: name, model: combo, baud: baud, civ: civ)
            var views: [NSView] = [header, settings, hint]
            for iface in radio.interfaces { views.append(interfaceRow(radio: radio, iface: iface)) }
            return column(views)
        }

        radioFields[radio.key] = RadioFields(name: name, model: combo, baud: baud, civ: civ)
        var views: [NSView] = [header, settings]
        for iface in radio.interfaces { views.append(interfaceRow(radio: radio, iface: iface)) }
        return column(views)
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

        let port = NSTextField(string: String(existing?.port ?? nextFreePort()))
        port.widthAnchor.constraint(equalToConstant: 62).isActive = true
        port.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.maximum = 65535
        port.formatter = fmt

        let line = NSStackView(views: [
            enable, path, NSView(),
            label("as", size: 11, secondary: true), name,
            label("TCP", size: 11, secondary: true), port,
        ])
        line.orientation = .horizontal
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)

        rows.append(IfaceRow(iface: iface, enable: enable, name: name, port: port,
                             existingID: existing?.id))
        return line
    }

    private func defaultName(for iface: Interface, on radio: Radio) -> String {
        radio.interfaces.count == 1 ? "main" : (iface.interfaceNumber.map { "port \($0)" } ?? "main")
    }

    private func nextFreePort() -> Int {
        var taken = Set(state.profiles.map { $0.port })
        for r in rows { if let p = Int(r.port.stringValue) { taken.insert(p) } }
        var port = 4532
        while taken.contains(port) { port += 1 }
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
        for radio in state.selectableRadios {
            guard let f = radioFields[radio.key] else { continue }
            out.append("\(f.name.stringValue)")
            out.append("   model   \(f.model.stringValue.isEmpty ? "(none - pick one)" : f.model.stringValue)")
            out.append("   choices \(f.model.numberOfItems) models, baud \(f.baud.titleOfSelectedItem ?? "?")")
            for row in rows where row.iface.radioKey == radio.key {
                out.append("   [\(row.enable.state == .on ? "x" : " ")] \(row.enable.title)"
                           + "  \(row.iface.devicePath)"
                           + "  as \(row.name.stringValue)  TCP \(row.port.stringValue)")
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

            guard let modelID = ModelTable.id(fromListing: fields.model.stringValue) else {
                alert("Choose a radio type for \(fields.name.stringValue).",
                      detail: fields.model.stringValue.isEmpty
                        ? "Nothing on a USB-serial adapter says which radio is behind it, so the model has to be set by hand. Type a model name such as IC-7300, or a Hamlib model number."
                        : "\"\(fields.model.stringValue)\" is not a Hamlib model. Type a model name or number.")
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
