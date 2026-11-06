// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TriKey",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TriKeyProbe", targets: ["TriKeyProbe"]),
               .executable(name: "TriKey", targets: ["TriKey"])],
    targets: [
        .target(name: "TriKeyHardware", path: "Sources/Trackpad"),
        .executableTarget(name: "TriKeyProbe", dependencies: ["TriKeyHardware"], path: "Sources/Probe"),
        .executableTarget(name: "TriKey", dependencies: ["TriKeyHardware"], path: "Sources",
                          exclude: ["Probe", "Trackpad"]),
        .testTarget(name: "TriKeyTests", dependencies: ["TriKey", "TriKeyHardware"], path: "Tests")
    ],
    swiftLanguageModes: [.v6]
)
