// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral domain core. Foundation only: no AppKit, no SwiftUI, no storage engine,
// no vendor SDK. Storage implementations (SQLite) live in separate targets behind `EventStore`.
let package = Package(
    name: "BipuuCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BipuuCore", targets: ["BipuuCore"]),
        .library(name: "BipuuSQLite", targets: ["BipuuSQLite"]),
    ],
    targets: [
        .target(name: "BipuuCore"),
        // Durable EventStore on the system sqlite3. Depends on the core; the core never on it.
        .target(name: "BipuuSQLite", dependencies: ["BipuuCore"]),
        // Shared check harness and the EventStore contract suite, run against every implementation.
        .target(name: "BipuuChecking", dependencies: ["BipuuCore"], path: "Checks/BipuuChecking"),
        // Checks run as a plain executable (`swift run BipuuCoreChecks`): they need neither Xcode
        // nor XCTest/swift-testing macros, so they behave the same locally and in CI.
        .executableTarget(name: "BipuuCoreChecks", dependencies: ["BipuuCore", "BipuuChecking"], path: "Checks/BipuuCoreChecks"),
        .executableTarget(name: "BipuuSQLiteChecks", dependencies: ["BipuuSQLite", "BipuuCore", "BipuuChecking"],
                          path: "Checks/BipuuSQLiteChecks"),
    ]
)
