// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TriKey",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TriKeyProbe", targets: ["TriKeyProbe"]),
               .executable(name: "TriKey", targets: ["TriKey"])],
    targets: [
        .target(name: "TriKeyHardware", path: "sources/trackpad"),
        .executableTarget(name: "TriKeyProbe", dependencies: ["TriKeyHardware"], path: "sources/probe"),
        .executableTarget(name: "TriKey", dependencies: ["TriKeyHardware"], path: "sources",
                          exclude: ["probe", "trackpad"]),
        .testTarget(name: "TriKeyTests", dependencies: ["TriKey", "TriKeyHardware"], path: "tests")
    ],
    swiftLanguageModes: [.v6]
)
