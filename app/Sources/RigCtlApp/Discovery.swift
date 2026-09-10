import Foundation
import IOKit
import IOKit.serial

/// One serial interface belonging to a radio.
struct Interface: Identifiable, Hashable {
    let devicePath: String        // /dev/cu.usbmodem114101
    let vendorID: Int?
    let productID: Int?
    let serialNumber: String?
    let interfaceNumber: Int?
    let productName: String?
    let vendorName: String?

    var id: String { devicePath }

    /// Identity of the physical radio, shared by all of its interfaces.
    var radioKey: String {
        if let s = serialNumber, !s.isEmpty {
            return "\(vendorID ?? -1):\(productID ?? -1):\(s)"
        }
        if let v = vendorID { return "\(v):\(productID ?? -1):\(devicePath)" }
        return devicePath
    }

    var radioName: String {
        productName ?? (devicePath as NSString).lastPathComponent
    }

    var label: String {
        if let n = interfaceNumber { return "interface \(n)" }
        return (devicePath as NSString).lastPathComponent
    }
}

/// A physical radio and the interfaces it presents.
struct Radio: Identifiable, Hashable {
    let key: String
    let name: String
    let vendorName: String?
    let serialNumber: String?
    var interfaces: [Interface]
    var id: String { key }
}

enum Discovery {
    /// Radios are reached through /dev/cu.usbmodem* only. Everything else on the
    /// bus - USB-serial bridges, Bluetooth ports, the debug console - is hidden
    /// unless `includeAll` is set.
    static func radios(includeAll: Bool = false) -> [Radio] {
        let found = interfaces(includeAll: includeAll)
        var order: [String] = []
        var byKey: [String: Radio] = [:]
        for i in found {
            if byKey[i.radioKey] == nil {
                order.append(i.radioKey)
                byKey[i.radioKey] = Radio(key: i.radioKey, name: i.radioName,
                                          vendorName: i.vendorName,
                                          serialNumber: i.serialNumber,
                                          interfaces: [])
            }
            byKey[i.radioKey]?.interfaces.append(i)
        }
        return order.compactMap { key in
            guard var r = byKey[key] else { return nil }
            r.interfaces.sort {
                ($0.interfaceNumber ?? 0, $0.devicePath) < ($1.interfaceNumber ?? 0, $1.devicePath)
            }
            return r
        }.sorted { $0.name < $1.name }
    }

    /// Never a radio, in any mode.
    private static let neverRadios: Set<String> = [
        "/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console",
    ]

    static func interfaces(includeAll: Bool = false) -> [Interface] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [Interface] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey) as? String else { continue }
            if neverRadios.contains(path) { continue }
            if !includeAll && !path.hasPrefix("/dev/cu.usbmodem") { continue }

            // USB identity lives on an ancestor of the serial client, so search
            // upwards through the service plane rather than on the node itself.
            out.append(Interface(
                devicePath: path,
                vendorID: ancestor(service, "idVendor") as? Int,
                productID: ancestor(service, "idProduct") as? Int,
                serialNumber: ancestor(service, "USB Serial Number") as? String,
                interfaceNumber: ancestor(service, "bInterfaceNumber") as? Int,
                productName: ancestor(service, "USB Product Name") as? String,
                vendorName: ancestor(service, "USB Vendor Name") as? String
            ))
        }
        return out
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func ancestor(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}
