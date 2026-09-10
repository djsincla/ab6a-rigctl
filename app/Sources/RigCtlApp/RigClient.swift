import Foundation
import CHamlib

/// Reads frequency and mode from a running rigctld.
///
/// This is a NETRIGCTL client: it speaks the rigctl protocol over TCP to a
/// daemon. It never opens a serial port - that interface already has an owner,
/// and an interface is never shared.
final class RigClient: @unchecked Sendable {
    struct Reading {
        var frequencyHz: Double
        var mode: String
        var passband: Int
    }

    private let queue = DispatchQueue(label: "shack.rigclient")
    private var rig: UnsafeMutablePointer<RIG>?
    private let hostPort: String

    init(port: Int) {
        self.hostPort = "localhost:\(port)"
        shk_quiet()
    }

    private func ensureOpen() -> Bool {
        if rig != nil { return true }
        var err: Int32 = 0
        guard let r = shk_open(hostPort, &err) else { return false }
        if err != 0 {
            shk_close(r)
            return false
        }
        rig = r
        return true
    }

    func close() {
        queue.sync {
            if let r = rig { shk_close(r) }
            rig = nil
        }
    }

    /// One reading, or nil if the daemon is not answering yet. A daemon that has
    /// only just started can briefly report RIG_EPOWER, so a failure here is
    /// worth retrying rather than treating as fatal.
    func read() -> Reading? {
        queue.sync {
            guard ensureOpen(), let r = rig else { return nil }
            var hz: Double = 0
            guard shk_get_freq(r, &hz) == RIG_OK.rawValue else {
                shk_close(r); rig = nil          // drop it; next call reconnects
                return nil
            }
            var buf = [CChar](repeating: 0, count: 32)
            var width: Int32 = 0
            let modeRC = shk_get_mode(r, &buf, 32, &width)
            let mode = modeRC == RIG_OK.rawValue ? String(cString: buf) : ""
            return Reading(frequencyHz: hz, mode: mode, passband: Int(width))
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
