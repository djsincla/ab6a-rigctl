import Foundation

/// Starts and stops rigctld, using the same pid/log files as the `ab6a-rigctl` CLI so
/// a daemon started by either is visible to both.
enum Daemons {
    static func pidFile(_ p: Profile) -> URL {
        Store.stateDir.appendingPathComponent("\(p.id).pid")
    }
    static func logFile(_ p: Profile) -> URL {
        Store.stateDir.appendingPathComponent("\(p.id).log")
    }

    static func command(_ p: Profile, device: String) -> [String] {
        var cmd = ["rigctld", "-m", String(p.model), "-r", device, "-t", String(p.port)]
        if let b = p.baud { cmd += ["-s", String(b)] }
        if let c = p.civaddr, !c.isEmpty { cmd += ["-c", c] }
        cmd += p.extraArgs ?? []
        return cmd
    }

    /// PID of this profile's rigctld, or nil. Confirms the process really is a
    /// rigctld before believing the pid file, in case the pid was recycled.
    static func runningPID(_ p: Profile) -> Int32? {
        guard let text = try? String(contentsOf: pidFile(p), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        guard processCommand(pid).contains("rigctld") else {
            try? FileManager.default.removeItem(at: pidFile(p))
            return nil
        }
        return pid
    }

    static func processCommand(_ pid: Int32) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func portIsOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    enum StartError: LocalizedError {
        case notConnected
        case interfaceTaken(by: String)
        case portBusy(Int)
        case exited(Int32, log: String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "That radio is not connected."
            case .interfaceTaken(let who): return "That interface is already open by \(who)."
            case .portBusy(let p): return "TCP port \(p) is already in use."
            case .exited(let code, let log): return "rigctld exited (status \(code)). \(log)"
            case .launchFailed(let m): return "Could not launch rigctld: \(m)"
            }
        }
    }

    @discardableResult
    static func start(_ p: Profile, interfaces: [Interface], others: [Profile]) throws -> Int32 {
        if let pid = runningPID(p) { return pid }
        guard let iface = p.match(in: interfaces) else { throw StartError.notConnected }

        // An interface has exactly one owner. Never share one.
        if let clash = others.first(where: {
            $0.id != p.id && runningPID($0) != nil
                && $0.match(in: interfaces)?.devicePath == iface.devicePath
        }) {
            throw StartError.interfaceTaken(by: clash.fullName)
        }
        if portIsOpen(p.port) { throw StartError.portBusy(p.port) }

        try FileManager.default.createDirectory(at: Store.stateDir, withIntermediateDirectories: true)
        let log = logFile(p)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: log) else {
            throw StartError.launchFailed("cannot open \(log.path)")
        }
        handle.seekToEndOfFile()
        let argv = command(p, device: iface.devicePath)
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle.write("\n=== \(stamp): \(argv.joined(separator: " ")) ===\n".data(using: .utf8)!)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        proc.standardOutput = handle
        proc.standardError = handle
        proc.standardInput = FileHandle.nullDevice
        // Launched from Finder the PATH is minimal; rigctld lives in Homebrew's bin.
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        }
        proc.environment = env

        do { try proc.run() } catch {
            throw StartError.launchFailed(error.localizedDescription)
        }

        // Let it fail loudly - a wrong model or a busy device exits at once.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if !proc.isRunning {
                let tail = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
                throw StartError.exited(proc.terminationStatus, log: tail)
            }
            if portIsOpen(p.port) { break }
            usleep(150_000)
        }

        try? String(proc.processIdentifier).write(to: pidFile(p), atomically: true, encoding: .utf8)
        return proc.processIdentifier
    }

    static func stop(_ p: Profile) {
        guard let pid = runningPID(p) else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !processCommand(pid).contains("rigctld") { break }
            usleep(100_000)
        }
        if processCommand(pid).contains("rigctld") { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile(p))
    }
}
