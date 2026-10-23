// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RestoreDock",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FirmwareCore", targets: ["FirmwareCore"]), .executable(name: "RestoreDock", targets: ["RestoreDock"])],
    targets: [
        .target(name: "FirmwareCore"),
        .executableTarget(name: "RestoreDock", dependencies: ["FirmwareCore"], resources: [.copy("Resources/DevicePhotos")]),
        .testTarget(name: "FirmwareCoreTests", dependencies: ["FirmwareCore"])
    ],
    swiftLanguageVersions: [.v5]
)
