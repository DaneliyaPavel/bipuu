// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral domain core. Foundation only: no AppKit, no SwiftUI, no storage engine,
// no vendor SDK. Storage implementations (SQLite) live in separate targets behind `EventStore`.
let package = Package(
    name: "BipuuCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BipuuCore", targets: ["BipuuCore"])],
    targets: [
        .target(name: "BipuuCore"),
        // Checks run as a plain executable (`swift run BipuuCoreChecks`): they need neither Xcode
        // nor XCTest/swift-testing macros, so they behave the same locally and in CI.
        .executableTarget(name: "BipuuCoreChecks", dependencies: ["BipuuCore"], path: "Checks/BipuuCoreChecks"),
    ]
)
