import SwiftUI

/// Neutral status avatar: a ring and a dot coloured by activity. Static (no timeline),
/// so it costs nothing while idle. Drawn at any size; the caller decides the frame.
///
/// This is the Phase 1 stand-in for the character system. Replace by implementing a
/// real renderer behind `CharacterRenderer`; keep the call sites.
struct AgentAvatarView: View {
    let snapshot: AvatarSnapshot

    init(snapshot: AvatarSnapshot) { self.snapshot = snapshot }

    init(task: AgentTask) {
        self.snapshot = AvatarSnapshot(
            agentId: task.id,
            activity: task.state,
            needsAttention: task.state == .approval || task.state == .question || task.state == .error)
    }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: max(1, d * 0.08))
                Circle()
                    .fill(color)
                    .frame(width: d * 0.38, height: d * 0.38)
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch snapshot.activity {
        case .idle, .sleeping:             return Color(white: 0.62)
        case .working, .searching:         return Color(red: 0.36, green: 0.62, blue: 1.0)
        case .thinking:                    return Color(red: 0.62, green: 0.52, blue: 1.0)
        case .approval, .question:         return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .error, .dizzy:               return Color(red: 1.0, green: 0.35, blue: 0.38)
        case .finished:                    return Color(red: 0.30, green: 0.80, blue: 0.55)
        case .ratelimit:                   return Color(red: 0.95, green: 0.55, blue: 0.30)
        }
    }

    private var label: String {
        switch snapshot.activity {
        case .idle: "Idle"
        case .working: "Working"
        case .thinking: "Thinking"
        case .searching: "Reading"
        case .approval: "Waiting for approval"
        case .question: "Waiting for an answer"
        case .error: "Error"
        case .finished: "Finished"
        case .ratelimit: "Rate limited"
        case .sleeping: "Idle"
        case .dizzy: "Error"
        }
    }
}
