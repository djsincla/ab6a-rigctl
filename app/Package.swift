// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RigCtlApp",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "RigCtlApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
    ]
)
