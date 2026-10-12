import Foundation

/// What an agent avatar has to communicate. Platform-neutral: no drawing, no AppKit.
///
/// The avatar is operational UI, not decoration: everything it shows is derived from
/// real agent/session state. A renderer receives a snapshot and draws it however it
/// likes; the product never depends on a particular character design.
struct AvatarSnapshot: Equatable {
    /// Stable identifier of the agent (not the host, not the session).
    var agentId: String
    /// What the agent is doing right now.
    var activity: BotState
    /// A human decision is required (approval, question, error to look at).
    var needsAttention: Bool = false
    /// Normalised direction the avatar should face, -1...1 on each axis. Optional polish.
    var look: AvatarLook? = nil
}

struct AvatarLook: Equatable {
    var x: Double
    var y: Double
}

/// Seam between product state and character rendering.
///
/// Implementations live in the UI layer (they return a view); this protocol only
/// pins down the inputs, so a renderer can be replaced independently of everything else.
protocol CharacterRenderer {
    /// Renderer identity, for diagnostics and settings.
    var identifier: String { get }
    /// True while the renderer needs frames. The host stops its display link/timeline
    /// when this is false, so an idle avatar costs nothing.
    func needsAnimation(for snapshot: AvatarSnapshot) -> Bool
}

/// Placeholder renderer: a plain status ring. Intentionally not a character.
/// It exists so the product runs without any character design until the original
/// Bipuu organism system lands (see docs/ROADMAP.md, Phase 6).
struct NullCharacterRenderer: CharacterRenderer {
    let identifier = "null"
    func needsAnimation(for snapshot: AvatarSnapshot) -> Bool { false }
}
