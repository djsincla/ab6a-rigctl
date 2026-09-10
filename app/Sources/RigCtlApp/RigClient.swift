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
    struct Reading {
        var frequencyHz: Double
        var mode: String
        var passband: Int
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
    func read() -> Reading? {
        queue.sync {
            guard let freqLines = ask("f", expecting: 1), let first = freqLines.first,
                  !first.hasPrefix("RPRT "), let hz = Double(first)
            else { return nil }

            var mode = ""
            var passband = 0
            if let modeLines = ask("m", expecting: 2), let m = modeLines.first,
               !m.hasPrefix("RPRT ") {
                mode = m
                if modeLines.count > 1 { passband = Int(modeLines[1]) ?? 0 }
            }
            return Reading(frequencyHz: hz, mode: mode, passband: passband)
        }
    }
}

extension RigClient.Reading {
    /// 14321000 -> "14.321.000"
    var frequencyText: String {
        let hz = Int(frequencyHz)
        guard hz > 0 else { return "-" }
        let s = String(hz)
        var out: [String] = []
        var rest = Substring(s)
        while rest.count > 3 {
            out.insert(String(rest.suffix(3)), at: 0)
            rest = rest.dropLast(3)
        }
        out.insert(String(rest), at: 0)
        return out.joined(separator: ".")
    }
}
