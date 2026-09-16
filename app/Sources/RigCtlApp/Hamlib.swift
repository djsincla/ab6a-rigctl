import Foundation

/// Finds a Hamlib that actually runs.
///
/// A machine can carry more than one Hamlib - a Homebrew one and, say, an older
/// hand-installed copy under /usr/local whose library has since been removed.
/// Whichever comes first on PATH wins, and an app launched from Finder inherits
/// a different PATH from a terminal, so the same rig can work from a shell and
/// fail from the app with nothing to show for it.
///
/// So rather than trusting PATH, each candidate is run and asked its version.
/// The first that answers is used, by absolute path.
enum Hamlib {
    private static var resolved: [String: String] = [:]
    private static var bannerCache: String?

    /// Directories worth looking in, before whatever PATH says.
    private static let searchPath: [String] = [
        "/opt/homebrew/bin",        // Apple silicon Homebrew
        "/usr/local/bin",           // Intel Homebrew, and hand-installs
        "/opt/local/bin",           // MacPorts
    ]

    /// Drop what was resolved, so a changed location takes effect at once.
    static func forget() {
        resolved.removeAll()
        bannerCache = nil
    }

    /// Absolute path to a working copy of a Hamlib tool, or the bare name if
    /// none answers - in which case launching it will fail loudly.
    static func tool(_ name: String) -> String {
        if let hit = resolved[name] { return hit }

        // A location given by the operator is authoritative: if it is set and
        // wrong, that should be visible rather than papered over by falling
        // back to something else.
        let chosen = ProcessInfo.processInfo.environment["AB6A_HAMLIB_DIR"]
            ?? Store.hamlibDir
        if let chosen, !chosen.isEmpty {
            let path = "\(chosen)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path), version(of: path) != nil {
                resolved[name] = path
                return path
            }
            resolved[name] = name
            return name
        }

        var candidates: [String] = searchPath.map { "\($0)/\(name)" }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if !candidates.contains(path) { candidates.append(path) }
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if version(of: path) != nil {
                resolved[name] = path
                return path
            }
        }
        resolved[name] = name
        return name
    }

    /// Runs one candidate and returns its version banner, or nil if it will not
    /// run at all - a missing library shows up here.
    private static func version(of path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.contains("Hamlib") ? line : nil
    }

    /// "4.7.2", or nil when no working Hamlib can be found.
    static var version: String? {
        guard let banner = workingBanner else { return nil }
        let parts = banner.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: "Hamlib"), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    private static var workingBanner: String? {
        let path = tool("rigctl")
        return path.contains("/") ? version(of: path) : nil
    }

    /// The banner plus where it came from - the path matters as much as the
    /// version when something is wrong.
    static var banner: String {
        if let cached = bannerCache { return cached }
        let path = tool("rigctl")
        let text: String
        if let v = workingBanner {
            text = "\(v)\n\(path)"
        } else {
            text = "No working Hamlib found. Install it with: brew install hamlib"
        }
        bannerCache = text
        return text
    }
}
