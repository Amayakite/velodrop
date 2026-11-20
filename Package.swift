// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VeloDrop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeloDrop", targets: ["VeloDrop"]),
        .executable(name: "VeloBridge", targets: ["VeloBridge"]),
        .executable(name: "VeloDropInstaller", targets: ["VeloDropInstaller"]),
    ],
    targets: [
        .target(name: "VeloCore"),
        .executableTarget(name: "VeloDrop", dependencies: ["VeloCore"]),
        .executableTarget(name: "VeloBridge", dependencies: ["VeloCore"]),
        .executableTarget(name: "VeloDropInstaller"),
        .executableTarget(name: "VeloCoreChecks", dependencies: ["VeloCore"],
                          path: "Tests/VeloCoreChecks"),
    ],
    swiftLanguageModes: [.v5]
)
