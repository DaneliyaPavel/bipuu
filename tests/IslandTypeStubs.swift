// Minimal stubs for IslandMode and IslandView — used only by standalone test compilation.
// The real definitions live in Sources/BipuuKit/IslandTypes.swift.
import Foundation

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case note, settings
}
