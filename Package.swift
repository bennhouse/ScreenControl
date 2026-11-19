// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScreenControl",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ScreenControl",
            path: "Sources/ScreenControl",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
