// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServerFinder",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "ServerFinderCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ServerFinder",
            dependencies: ["ServerFinderCore"]
        ),
        .testTarget(
            name: "ServerFinderCoreTests",
            dependencies: ["ServerFinderCore"]
        ),
    ]
)
