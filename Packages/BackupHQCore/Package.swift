// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupHQCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BackupHQCore", targets: ["BackupHQCore"]),
        .executable(name: "backuphq-cli", targets: ["backuphq-cli"]),
    ],
    targets: [
        .target(
            name: "BackupHQCore",
            path: "Sources/BackupHQCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "backuphq-cli",
            dependencies: ["BackupHQCore"],
            path: "Sources/backuphq-cli"
        ),
        .testTarget(
            name: "BackupHQCoreTests",
            dependencies: ["BackupHQCore"],
            path: "Tests/BackupHQCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
