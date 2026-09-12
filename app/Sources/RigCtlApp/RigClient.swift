import Foundation

/// Reads frequency and mode from a running rigctld.
///
/// Speaks the rigctl network protocol over a plain socket. This is a client of
/// the daemon and never opens a serial port - that interface already has an
/// owner, and an interface is never shared.
///
/// Hamlib's own NETRIGCTL backend would do the same job, but linking libhamlib
/// for `f\n` and `m\n` means a C shim (Hamlib's API is largely function-like
/// macros, which Swift cannot import) plus bundling and re-signing libhamlib
/// and libusb to satisfy hardened-runtime library validation. Not worth it for
/// two commands.
final class RigClient: @unchecked Sendable {
    /// What a daemon reports, by kind. `primary` is the emphasised value.
    struct Reading {
        var primary: String
        var secondary: String
    }

    private let queue = DispatchQueue(label: "rigctl.client")
    private let port: Int
    private var fd: Int32 = -1

    init(port: Int) { self.port = port }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    // MARK: connection

    private func ensureOpen() -> Bool {
        if fd >= 0 { return true }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { Darwin.close(sock); return false }
        fd = sock
        return true
    }

    private func drop() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    func close() { queue.sync { drop() } }

    // MARK: protocol

    /// Sends one command and reads `expecting` reply lines.
    ///
    /// rigctld answers a failed command with a single "RPRT <negative errno>",
    /// so a short reply is not necessarily a truncated one.
    private func ask(_ command: String, expecting: Int) -> [String]? {
        guard ensureOpen() else { return nil }
        let out = Array((command + "\n").utf8)
        let sent = out.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == out.count else { drop(); return nil }

        var lines: [String] = []
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256)

        while lines.count < expecting {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { drop(); return nil }
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                buffer = buffer[buffer.index(after: nl)...]
                if !line.isEmpty { lines.append(line) }
                if line.hasPrefix("RPRT ") { return lines }   // error, no more coming
            }
        }
        return lines
    }

    /// One reading, or nil if the daemon is not answering yet. A daemon that has
    /// only just started can briefly fail, so this is worth retrying rather than
    /// treating as fatal.
    func read(kind: DeviceKind, vfo: String? = nil) -> Reading? {
        queue.sync {
            switch kind {
            case .rig:
                // Naming a VFO needs get_vfo_info: plain `f` reports whichever
                // VFO the rig currently has selected, and `f Main` is ignored
                // unless the daemon was started in VFO mode.
                if let vfo, !vfo.isEmpty {
                    guard let lines = ask("\\get_vfo_info \(vfo)", expecting: 3),
                          let first = lines.first, !first.hasPrefix("RPRT "),
                          let hz = Double(first) else { return nil }
                    let mode = lines.count > 1 ? lines[1] : ""
                    return Reading(primary: "\(Self.frequencyText(hz)) MHz",
                                   secondary: [vfo, mode].filter { !$0.isEmpty }
                                       .joined(separator: "  "))
                }
                guard let freq = ask("f", expecting: 1)?.first,
                      !freq.hasPrefix("RPRT "), let hz = Double(freq) else { return nil }
                var mode = ""
                if let lines = ask("m", expecting: 2), let m = lines.first,
                   !m.hasPrefix("RPRT ") {
                    mode = m
                }
                return Reading(primary: "\(Self.frequencyText(hz)) MHz", secondary: mode)

            case .rotator:
                // get_pos answers with azimuth then elevation
                guard let lines = ask("p", expecting: 2), lines.count >= 2,
                      !lines[0].hasPrefix("RPRT "),
                      let az = Double(lines[0]), let el = Double(lines[1]) else { return nil }
                return Reading(primary: String(format: "az %.0f\u{00B0}   el %.0f\u{00B0}", az, el),
                               secondary: "")

            case .amplifier:
                guard let line = ask("l SWR", expecting: 1)?.first,
                      !line.hasPrefix("RPRT "), let swr = Double(line) else { return nil }
                return Reading(primary: String(format: "SWR %.2f", swr), secondary: "")
            }
        }
    }

    /// 14321000 -> "14.321.000"
    static func frequencyText(_ hz: Double) -> String {
        let n = Int(hz)
        guard n > 0 else { return "-" }
        var out: [String] = []
        var rest = Substring(String(n))
        while rest.count > 3 {
            out.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        out.insert(String(rest), at: 0)
        return out.joined(separator: ".")
    }
}
