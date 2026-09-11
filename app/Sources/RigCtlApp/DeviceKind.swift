import Foundation

/// Hamlib keeps transceivers, rotators and amplifiers apart: separate daemons,
/// separate model tables, separate default ports and separate protocols. A
/// rotator model number handed to rigctld is simply rejected.
enum DeviceKind: String, CaseIterable, Codable {
    case rig
    case rotator
    case amplifier

    var displayName: String {
        switch self {
        case .rig: return "Radio"
        case .rotator: return "Rotator"
        case .amplifier: return "Amplifier"
        }
    }

    /// The daemon that owns the serial port and serves the network protocol.
    var daemon: String {
        switch self {
        case .rig: return "rigctld"
        case .rotator: return "rotctld"
        case .amplifier: return "ampctld"
        }
    }

    /// The tool that prints this kind's model table.
    var lister: String {
        switch self {
        case .rig: return "rigctl"
        case .rotator: return "rotctl"
        case .amplifier: return "ampctl"
        }
    }

    /// Hamlib's own default, reserved per kind so the port picker does not hand
    /// a second radio the port a rotator will want.
    var defaultPort: Int {
        switch self {
        case .rig: return 4532
        case .rotator: return 4533
        case .amplifier: return 4531
        }
    }

    /// Ports reserved by the other kinds, which the picker steps over.
    static var reservedPorts: Set<Int> {
        Set(allCases.map { $0.defaultPort })
    }

    /// What to ask the daemon for, and how many reply lines to expect.
    var query: [(command: String, lines: Int)] {
        switch self {
        case .rig: return [("f", 1), ("m", 2)]
        case .rotator: return [("p", 2)]
        case .amplifier: return [("l SWR", 1)]
        }
    }
}
