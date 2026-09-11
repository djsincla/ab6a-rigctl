import Foundation

/// Hamlib's rig model table, read once from `rigctl -l`.
///
/// Hamlib does not probe a radio to identify it - the table is static, and the
/// radio's own USB descriptor is what tells us which row applies.
struct RigModel: Hashable {
    var id: Int
    var manufacturer: String
    var model: String
    var status: String

    var label: String {
        let base = "\(manufacturer) \(model)"
        return status.lowercased() == "stable" ? base : "\(base) (\(status))"
    }
    /// What the combo box shows. Model first, so typing "IC-7" completes -
    /// people look for a radio by its model, not its manufacturer.
    var listing: String {
        let suffix = status.lowercased() == "stable" ? "" : ", \(status)"
        return "\(model) - \(manufacturer) (\(id)\(suffix))"
    }
}

enum ModelTable {
    // one table per kind: rigctl -l, rotctl -l and ampctl -l are different lists
    private static var cache: [DeviceKind: [Int: String]] = [:]
    private static var models: [DeviceKind: [RigModel]] = [:]
    private static var loadedKinds: Set<DeviceKind> = []

    static func name(for id: Int, kind: DeviceKind = .rig) -> String {
        load(kind)
        return cache[kind]?[id] ?? "model \(id)"
    }

    static func all(_ kind: DeviceKind = .rig) -> [RigModel] {
        load(kind)
        return models[kind] ?? []
    }

    static func model(withID id: Int, kind: DeviceKind = .rig) -> RigModel? {
        load(kind)
        return models[kind]?.first { $0.id == id }
    }

    /// Parse "IC-7760 - Icom (3092)" back to 3092. A bare number works too, so
    /// a model number can simply be typed.
    static func id(fromListing text: String, kind: DeviceKind = .rig) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return model(withID: n, kind: kind) != nil ? n : nil }
        load(kind)
        let models = self.models[kind] ?? []
        if let m = models.first(where: { $0.listing == trimmed }) { return m.id }
        // "(3092)" or "(3092, Alpha)" at the end
        if let open = trimmed.lastIndex(of: "("), let close = trimmed.lastIndex(of: ")"),
           open < close {
            let inner = trimmed[trimmed.index(after: open)..<close]
            let digits = inner.prefix { $0.isNumber }
            if let n = Int(digits), model(withID: n) != nil { return n }
        }
        let needle = normalise(trimmed)
        return models.first { normalise($0.model) == needle }?.id
    }

    /// Hamlib never probes a radio. The USB product string is what identifies
    /// it, so match that against the model table; a generic USB-serial bridge
    /// yields nothing and the operator picks.
    static func suggestions(forProduct product: String?, kind: DeviceKind = .rig) -> [RigModel] {
        load(kind)
        let models = self.models[kind] ?? []
        guard let product, !product.isEmpty else { return [] }
        let needle = normalise(product)
        guard !needle.isEmpty else { return [] }
        var exact: [RigModel] = [], partial: [RigModel] = []
        for m in models {
            let n = normalise(m.model)
            guard n.count >= 3 else { continue }
            if n == needle { exact.append(m) }
            else if needle.contains(n) || (needle.count >= 4 && n.contains(needle)) {
                partial.append(m)
            }
        }
        return Array((exact + partial).prefix(8))
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func load(_ kind: DeviceKind) {
        guard !loadedKinds.contains(kind) else { return }
        loadedKinds.insert(kind)
        var table: [Int: String] = [:]
        var list: [RigModel] = []
        defer { cache[kind] = table; models[kind] = list }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [kind.lister, "-l"]
        var env = ProcessInfo.processInfo.environment
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"]
        where !(env["PATH"] ?? "").contains(extra) {
            env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let id = Int(trimmed[trimmed.startIndex..<space]) else { continue }
            let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
            let cols = rest.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cols.count >= 2 else { continue }
            var label = "\(cols[0]) \(cols[1])"
            if cols.count >= 4, cols[3].lowercased() != "stable" {
                label += " (\(cols[3]))"
            }
            table[id] = label
            list.append(RigModel(id: id, manufacturer: cols[0], model: cols[1],
                                 status: cols.count >= 4 ? cols[3] : ""))
        }
    }
}
