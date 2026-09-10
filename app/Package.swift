// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RigCtlApp",
    platforms: [.macOS("26.0")],
    targets: [
        // Hamlib exposes much of its API as function-like macros, which Swift
        // cannot import; shim.h wraps the ones we need in real functions.
        .systemLibrary(name: "CHamlib", pkgConfig: "hamlib"),
        .executableTarget(
            name: "RigCtlApp",
            dependencies: ["CHamlib"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
    ]
)
