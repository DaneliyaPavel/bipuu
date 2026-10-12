import Foundation

/// Stable, typed identifier. The phantom `Entity` makes `ProjectID` and `TaskID` different
/// types, so they cannot be mixed up. Encodes as a single JSON string and persists as TEXT.
public struct Identifier<Entity>: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// A fresh random identifier (lower-case UUID text).
    public static func generate() -> Identifier { Identifier(UUID().uuidString.lowercased()) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    /// UTF-8 byte order, so every store (in memory, a database BINARY collation) sorts ids identically.
    public static func < (a: Identifier, b: Identifier) -> Bool {
        a.rawValue.utf8.lexicographicallyPrecedes(b.rawValue.utf8)
    }
    public static func == (a: Identifier, b: Identifier) -> Bool { a.rawValue == b.rawValue }
    public func hash(into h: inout Hasher) { h.combine(rawValue) }
}

/// Open vocabulary value: a string with well-known constants, but never a closed enum.
/// Unknown values decode and round-trip unchanged, so old code can read data written by newer code.
public struct Token<Tag>: Hashable, Sendable, Codable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public static func < (a: Token, b: Token) -> Bool { a.rawValue < b.rawValue }
    public static func == (a: Token, b: Token) -> Bool { a.rawValue == b.rawValue }
    public func hash(into h: inout Hasher) { h.combine(rawValue) }
}

public typealias ProjectID = Identifier<Project>
public typealias TaskID = Identifier<WorkTask>
public typealias AgentID = Identifier<Agent>
public typealias SessionID = Identifier<Session>
public typealias HostID = Identifier<Host>
public typealias EnvironmentID = Identifier<Environment>
public typealias ApprovalID = Identifier<Approval>
public typealias ArtifactID = Identifier<Artifact>
public typealias EventID = Identifier<AgentEvent>
