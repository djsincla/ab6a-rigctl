import Foundation

/// What Hamlib is installed, for the About panel and for support questions.
///
/// The first thing worth knowing when a setup misbehaves is which Hamlib is
/// underneath it: backends change between releases, and a rig marked Alpha in
/// one version may behave differently in the next.
enum Hamlib {
    private static var cached: String?

    /// "4.7.2", or nil when rigctl cannot be run at all.
    static var version: String? {
        if let cached { return cached.isEmpty ? nil : cached }
        let raw = run(["rigctl", "--version"])
        // rigctl Hamlib 4.7.2 2026-06-21T13:07:37Z SHA=40f63488f 64-bit
        let parts = raw.split(separator: " ").map(String.init)
        var found = ""
        if let i = parts.firstIndex(of: "Hamlib"), i + 1 < parts.count {
            found = parts[i + 1]
        }
        cached = found
        return found.isEmpty ? nil : found
    }

    /// The full banner, useful verbatim in a support message.
    static var banner: String {
        let raw = run(["rigctl", "--version"])
        return raw.isEmpty ? "Hamlib not found on PATH" : raw
    }

    private static func run(_ argv: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        var env = ProcessInfo.processInfo.environment
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"]
        where !(env["PATH"] ?? "").contains(extra) {
            env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
