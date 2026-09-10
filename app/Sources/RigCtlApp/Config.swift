import Foundation

/// A daemon: one rigctld on one interface, on one TCP port.
///
/// Read and written in the same ~/.config/shack/profiles.json the `ab6a-rigctl` CLI
/// uses, with identical keys, so the two cannot disagree about your radios.
struct Profile: Codable, Identifiable, Hashable {
    struct RadioRef: Codable, Hashable {
        var key: String
        var name: String
        var serial: String?
    }

    /// USB fingerprint - a radio moved to another port is still recognised,
    /// which a /dev path alone could not manage.
    struct DeviceRef: Codable, Hashable {
        var vid: Int?
        var pid: Int?
        var serial: String?
        var interfaceNumber: Int?
        var product: String?
        var vendor: String?
        var dev: String?

        enum CodingKeys: String, CodingKey {
            case vid, pid, serial, product, vendor, dev
            case interfaceNumber = "interface"
        }
    }

    var id: String
    var name: String
    var radio: RadioRef?
    var model: Int
    var baud: Int?
    var port: Int
    var civaddr: String?
    var extraArgs: [String]?
    var device: DeviceRef

    enum CodingKeys: String, CodingKey {
        case id, name, radio, model, baud, port, civaddr, device
        case extraArgs = "extra_args"
    }

    var radioName: String { radio?.name ?? name }
    var fullName: String {
        radioName == name ? name : "\(radioName) / \(name)"
    }

    /// The attached interface matching this profile's fingerprint, if any.
    func match(in interfaces: [Interface]) -> Interface? {
        if let s = device.serial, let v = device.vid {
            if let hit = interfaces.first(where: {
                $0.vendorID == v && $0.productID == device.pid
                    && $0.serialNumber == s && $0.interfaceNumber == device.interfaceNumber
            }) { return hit }
        }
        if let v = device.vid {
            let same = interfaces.filter {
                $0.vendorID == v && $0.productID == device.pid
                    && $0.interfaceNumber == device.interfaceNumber
            }
            if same.count == 1 { return same[0] }
        }
        if let dev = device.dev {
            return interfaces.first { $0.devicePath == dev }
        }
        return nil
    }
}

struct ConfigFile: Codable {
    var profiles: [Profile]
}

enum Store {
    static let configDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/ab6a-rigctl")
    static let configURL = configDir.appendingPathComponent("profiles.json")
    static let stateDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/state/ab6a-rigctl")

    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        let dec = JSONDecoder()
        return (try? dec.decode(ConfigFile.self, from: data))?.profiles ?? []
    }

    static func save(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(ConfigFile(profiles: profiles))
        data.append(0x0A)
        let tmp = configURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }
}
