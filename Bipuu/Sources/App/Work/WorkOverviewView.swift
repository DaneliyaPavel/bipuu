import SwiftUI
import BipuuCore

// MARK: - Words (pure, tested)

/// The sentences the work view shows, kept apart from the layout so they can be tested.
enum WorkText {
    /// "2 sessions · 1 working", "Needs you · 1 approval", "1 session · idle", "Not started".
    static func summary(_ row: TaskRow) -> String {
        let s = row.summary
        if s.sessionCount == 0 { return String(localized: "work.noSessions", defaultValue: "No sessions") }
        var parts: [String] = []
        if s.pendingApprovalCount > 0 {
            parts.append(s.pendingApprovalCount == 1
                ? String(localized: "work.oneApproval", defaultValue: "Needs you · 1 approval")
                : String(format: String(localized: "work.manyApprovals", defaultValue: "Needs you · %lld approvals"), Int64(s.pendingApprovalCount)))
        } else if s.openQuestionCount > 0 {
            parts.append(String(localized: "work.question", defaultValue: "Needs you · question"))
        }
        parts.append(s.sessionCount == 1
            ? String(localized: "work.oneSession", defaultValue: "1 session")
            : String(format: String(localized: "work.manySessions", defaultValue: "%lld sessions"), Int64(s.sessionCount)))
        if !row.needsAttention {
            if s.workingSessionCount > 0 {
                parts.append(String(format: String(localized: "work.working", defaultValue: "%lld working"), Int64(s.workingSessionCount)))
            } else if s.liveSessionCount > 0 {
                parts.append(String(localized: "work.idle", defaultValue: "idle"))
            } else {
                parts.append(String(localized: "work.finished", defaultValue: "finished"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// How long ago, abbreviated ("3m", "2h", "1d"); "now" under 45 s; "" when there is nothing to say.
    static func age(of date: Date, now: Date) -> String {
        guard date > .distantPast, now.timeIntervalSince(date) >= 0 else { return "" }
        if now.timeIntervalSince(date) < 45 { return String(localized: "work.now", defaultValue: "now") }
        // "3m", "2h", "1d" in the user's language: how long ago, with no sign.
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 1
        return f.string(from: date, to: now) ?? ""
    }

    static func unattached(_ count: Int) -> String {
        count == 1 ? String(localized: "work.oneUnattached", defaultValue: "1 session without a task")
                   : String(format: String(localized: "work.manyUnattached", defaultValue: "%lld sessions without a task"), Int64(count))
    }

    static func hidden(_ count: Int) -> String {
        String(format: String(localized: "work.hidden", defaultValue: "+%lld more tasks"), Int64(count))
    }

    /// One sentence for assistive technology.
    static func spoken(_ row: TaskRow, now: Date) -> String {
        var s = "\(row.task.title). \(summary(row))."
        if row.isProposed { s += " " + String(localized: "work.proposedSpoken", defaultValue: "Proposed by Bipuu, not confirmed.") }
        let a = age(of: row.lastActivity, now: now)
        if !a.isEmpty { s += " \(a)." }
        return s
    }
}

// MARK: - The list (no state of its own except the rename field)

/// Projects → open tasks → what their sessions are doing. Pure: it shows an overview and reports
/// what the user did through closures, so it can be rendered with fixtures.
struct WorkOverviewList: View {
    let overview: WorkOverview
    let now: Date
    var onConfirm: (TaskID) -> Void = { _ in }
    var onRename: (TaskID, String) -> Void = { _, _ in }

    @State private var editing: TaskID?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private let amber = Color(hex: "#FFB84D"), blue = Color(hex: "#5C9EFF"), grey = Color(hex: "#6B7079")
    private let primary = Color(hex: "#F5F6F8"), secondary = Color(hex: "#8E939C")

    var body: some View {
        if overview.isEmpty {
            VStack(spacing: 4) {
                Text(String(localized: "work.empty.title", defaultValue: "No work recorded yet"))
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                Text(String(localized: "work.empty.hint", defaultValue: "Sessions and tasks appear here as your agents work."))
                    .font(.system(size: 11)).foregroundColor(secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(overview.groups.enumerated()), id: \.offset) { _, group in
                        groupHeader(group)
                        ForEach(group.tasks, id: \.task.id) { row in taskRow(row) }
                    }
                    if overview.unattachedSessionCount > 0 {
                        footer(WorkText.unattached(overview.unattachedSessionCount), symbol: "circle.dashed")
                    }
                    if overview.hiddenTaskCount > 0 {
                        footer(WorkText.hidden(overview.hiddenTaskCount), symbol: "ellipsis")
                    }
                }
                .padding(.vertical, 2)
            }
            // A soft fade at the bottom says "there is more": the island is too short to show every task.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86),
                                         .init(color: .black.opacity(0.1), location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func groupHeader(_ group: ProjectGroup) -> some View {
        Text((group.project?.name ?? String(localized: "work.noProject", defaultValue: "No project")).uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
            .foregroundColor(secondary)
            .lineLimit(1)
            .padding(.top, 5).padding(.bottom, 1)
            .accessibilityAddTraits(.isHeader)
    }

    private func taskRow(_ row: TaskRow) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot(for: row)).frame(width: 7, height: 7)
            if editing == row.task.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(primary)
                    .focused($fieldFocused)
                    .onSubmit { commit(row) }
                    .onExitCommand { editing = nil }
                    .accessibilityLabel(String(localized: "work.renameField", defaultValue: "Task name"))
            } else {
                Text(row.task.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(primary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    .contentShape(Rectangle())
                    .onTapGesture { draft = row.task.title; editing = row.task.id; fieldFocused = true }
                    .help(String(localized: "work.renameHelp", defaultValue: "Click to rename"))
            }
            if row.isProposed {
                Text(String(localized: "work.proposed", defaultValue: "Proposed"))
                    .font(.system(size: 9.5, weight: .medium)).foregroundColor(secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .overlay(Capsule().stroke(secondary.opacity(0.55), lineWidth: 0.8))
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Text(WorkText.summary(row))
                .font(.system(size: 11)).foregroundColor(row.needsAttention ? amber : secondary)
                .lineLimit(1).truncationMode(.tail)
            let age = WorkText.age(of: row.lastActivity, now: now)
            if !age.isEmpty {
                Text(age).font(.system(size: 11)).foregroundColor(grey).lineLimit(1).fixedSize()
            }
            if row.isProposed {
                Button { onConfirm(row.task.id) } label: {
                    Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundColor(secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "work.confirmHelp", defaultValue: "Confirm this task"))
                .accessibilityLabel(String(localized: "work.confirm", defaultValue: "Confirm task"))
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WorkText.spoken(row, now: now))
    }

    private func footer(_ text: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundColor(grey).frame(width: 7)
            Text(text).font(.system(size: 11)).foregroundColor(secondary)
        }
        .frame(height: 22)
    }

    private func dot(for row: TaskRow) -> Color {
        if row.needsAttention { return amber }
        if row.summary.workingSessionCount > 0 { return blue }
        return row.summary.liveSessionCount > 0 ? grey : grey.opacity(0.4)
    }

    private func commit(_ row: TaskRow) {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !title.isEmpty, title != row.task.title else { return }
        onRename(row.task.id, title)
    }
}
