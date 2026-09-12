import Foundation

struct DaemonStatus {
    var pid: Int32?
    var devicePath: String?
    var lastError: String?
    var running: Bool { pid != nil }
    var connected: Bool { devicePath != nil }
}

@MainActor
final class AppState {
    private(set) var profiles: [Profile] = []
    private(set) var radios: [Radio] = []
    private(set) var status: [String: DaemonStatus] = [:]
    var busy: Set<String> = []

    /// Called on the main actor whenever anything above changes.
    var onChange: (() -> Void)?

    /// Background polling, independent of the main run loop.
    let poller = RigPoller()

    init() {
        refresh()
        // polling is driven by StatusController, which needs it to keep running
        // while a menu is tracking events
    }

    var anyRunning: Bool { status.values.contains { $0.running } }

    /// Config profiles grouped by the radio they belong to, in file order.
    var groupedProfiles: [(radio: String, profiles: [Profile])] {
        var order: [String] = []
        var byKey: [String: [Profile]] = [:]
        for p in profiles {
            let key = p.radio?.key ?? p.id
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(p)
        }
        return order.compactMap { key in
            guard let ps = byKey[key], let first = ps.first else { return nil }
            return (first.radioName, ps)
        }
    }

    /// Attached radios that have no daemons configured yet.
    ///
    /// Filtered to /dev/cu.usbmodem* unless showAllDevices is set - most of what
    /// is on the bus is not a radio, and a generic USB-serial bridge cannot say
    /// what is behind it.
    var unconfiguredRadios: [Radio] {
        let claimed = Set(profiles.compactMap { $0.radio?.key })
        return radios.filter { r in
            guard !claimed.contains(r.key) else { return false }
            return showAllDevices || r.interfaces.contains {
                $0.devicePath.hasPrefix("/dev/cu.usbmodem")
            }
        }
    }

    /// Radios offered in the configuration window.
    var selectableRadios: [Radio] {
        showAllDevices ? radios : radios.filter { r in
            r.interfaces.contains { $0.devicePath.hasPrefix("/dev/cu.usbmodem") }
                || profiles.contains { $0.radio?.key == r.key }
        }
    }

    /// Whether the *pick a device* lists show every serial device or only
    /// /dev/cu.usbmodem*. Matching always considers every device, so a radio
    /// configured behind a USB-serial bridge still resolves.
    var showAllDevices: Bool {
        get { UserDefaults.standard.bool(forKey: "showAllDevices") }
        set { UserDefaults.standard.set(newValue, forKey: "showAllDevices"); refresh() }
    }

    func refresh() {
        let loaded = Store.load()
        let found = Discovery.radios(includeAll: true)
        let ifaces = found.flatMap { $0.interfaces }

        var next: [String: DaemonStatus] = [:]
        for p in loaded {
            let pid = Daemons.runningPID(p)
            let iface = p.match(in: ifaces)
            let st = DaemonStatus(pid: pid, devicePath: iface?.devicePath,
                                  lastError: status[p.id]?.lastError)
            next[p.id] = st
        }
        profiles = loaded
        radios = found
        status = next
        poller.setTargets(loaded.compactMap { p in
            next[p.id]?.running == true
                ? (id: p.id, port: p.port, kind: p.deviceKind, vfo: p.vfo) : nil
        })
        onChange?()
    }

    /// Latest cached reading for a daemon. Safe to call from a menu-tracking
    /// run loop: it takes a lock, never waits on the main actor.
    func reading(_ id: String) -> RigClient.Reading? { poller.reading(id) }

    func toggle(_ p: Profile) {
        if status[p.id]?.running == true { stop(p) } else { start(p) }
    }

    func start(_ p: Profile) {
        guard !busy.contains(p.id) else { return }
        busy.insert(p.id)
        let all = profiles
        Task.detached(priority: .userInitiated) {
            let ifaces = Discovery.radios().flatMap { $0.interfaces }
            let message: String?
            do {
                try Daemons.start(p, interfaces: ifaces, others: all)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(p.id)
                self.status[p.id]?.lastError = message
                self.refresh()
            }
        }
    }

    func stop(_ p: Profile) {
        guard !busy.contains(p.id) else { return }
        busy.insert(p.id)
        Task.detached(priority: .userInitiated) {
            Daemons.stop(p)
            await MainActor.run {
                self.busy.remove(p.id)
                self.status[p.id]?.lastError = nil
                self.refresh()
            }
        }
    }

    func startAllConnected() {
        for p in profiles where status[p.id]?.connected == true
            && status[p.id]?.running != true {
            start(p)
        }
    }

    func stopAll() {
        for p in profiles where status[p.id]?.running == true { stop(p) }
    }
}
