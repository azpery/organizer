// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Organizer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Organizer",
            path: "Sources/Organizer",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
