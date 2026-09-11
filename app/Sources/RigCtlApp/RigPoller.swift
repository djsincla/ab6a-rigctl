import Foundation

/// Polls every running daemon on its own background thread and caches the
/// latest reading.
///
/// The menu cannot rely on Swift concurrency here: while an NSMenu is tracking,
/// the main run loop is in a modal event-tracking mode and main-actor
/// continuations do not drain, so a reading fetched via `await MainActor.run`
/// never arrives until the menu closes. A background timer writing into a
/// lock-guarded cache keeps working regardless, and the menu just reads the
/// cache synchronously from its own run-loop timer.
final class RigPoller: @unchecked Sendable {
    private struct Target {
        let id: String
        let port: Int
        let kind: DeviceKind
    }

    private let lock = NSLock()
    private var targets: [Target] = []
    private var cache: [String: RigClient.Reading] = [:]
    private var clients: [String: RigClient] = [:]

    private let queue = DispatchQueue(label: "rigctl.poller")
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval = 1.0) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: interval)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// Which daemons are running, and on which ports. Called whenever the
    /// configuration or the set of running daemons changes.
    func setTargets(_ pairs: [(id: String, port: Int, kind: DeviceKind)]) {
        lock.lock()
        targets = pairs.map { Target(id: $0.id, port: $0.port, kind: $0.kind) }
        let live = Set(pairs.map { $0.id })
        for (id, client) in clients where !live.contains(id) {
            client.close()
            clients[id] = nil
            cache[id] = nil
        }
        lock.unlock()
    }

    func reading(_ id: String) -> RigClient.Reading? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    private func sweep() {
        lock.lock()
        let current = targets
        var use: [(String, RigClient, DeviceKind)] = []
        for t in current {
            if let c = clients[t.id] {
                use.append((t.id, c, t.kind))
            } else {
                let c = RigClient(port: t.port)
                clients[t.id] = c
                use.append((t.id, c, t.kind))
            }
        }
        lock.unlock()

        for (id, client, kind) in use {
            let r = client.read(kind: kind)
            lock.lock()
            cache[id] = r
            lock.unlock()
        }
    }
}
