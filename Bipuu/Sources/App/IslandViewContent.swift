import SwiftUI

// MARK: - Dispatch view content by IslandView

struct IslandViewContent: View {
    let view: IslandView
    @ObservedObject var state: AppState

    var body: some View {
        switch view {
        case .overview:  OverviewView(state: state)
        case .empty:     EmptyStateView(state: state)
        case .approval:  ApprovalView(state: state)
        case .question:  QuestionView(state: state)
        case .error:     ErrorView(state: state)
        case .finished:  FinishedView(state: state)
        case .note:      NoteView(state: state)
        case .settings:  SettingsIslandView(state: state)
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var showingN8nDetail = false
    @State private var activeDiffId: Int? = nil

    var agent: AgentTask? { state.focusTask }

    var body: some View {
        HStack(spacing: 10) {
            // Left card: title row + ticker below + ↗ button overlay
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)

                // Title row + ticker stacked (or integration card)
                if let agent = agent {
                    Group {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: agent.color))
                                    .frame(width: 7, height: 7)
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#F5F6F8"))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                Text({ () -> String in
                                    switch agent.source {
                                    case .claudeCode: return "Claude Code"
                                    case .agent:      return "Agent"
                                                    }
                                }())
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8E939C"))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 2)
                                if agent.steps.count > 1 {
                                    Text("\(min(agent.stepIndex + 1, agent.steps.count))/\(agent.steps.count)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#6B7079"))
                                        .fixedSize()
                                }
                            }
                            .padding(.top, 6)
                            .padding(.leading, 108)
                            .padding(.trailing, 36)

                            TickerView(task: agent, onDiffTap: { diffIdx in
                                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = diffIdx }
                            })
                                .frame(height: 44)
                                .padding(.top, 6)
                                .padding(.leading, 108)
                                .padding(.trailing, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                    }
                }

                // Plan detail overlays on top of normal content (GitHub build, home view only)
                if state.showingPlanDetail {
                    CardBackground(wash: nil)
                    Group {
                        if state.planDetailIsCodex {
                            CodexPlanCardView(usage: state.codexPlanUsage)
                        } else {
                            // Claude and Codex both on: the header shows only the Claude pill,
                            // Codex is a third row here that opens its own card.
                            let bothPlans = state.showPlanInNotch && state.planRelayInstalled
                                && state.showCodexPlanInNotch
                            ClaudePlanCardView(usage: state.claudePlanUsage,
                                               codexRow: bothPlans,
                                               codexUsage: state.codexPlanUsage,
                                               onCodex: {
                                                   withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                       state.planDetailIsCodex = true
                                                   }
                                                   state.refreshCodexPlanUsage()
                                               })
                        }
                    }
                    .transition(.opacity)
                }

                // Diff overlay — replaces ticker when a diff step is tapped
                if let diffId = activeDiffId,
                   let task = agent,
                   let diff = state.sessionDiffs[task.id]?.first(where: { $0.id == diffId }) {
                    CardBackground(wash: nil)
                    DiffCardView(diff: diff, onDismiss: { activeDiffId = nil })
                        .transition(.opacity)
                }

                // ↗ jump button — last in ZStack so it renders on top; hidden while any detail is open
                let hideJumpButton = showingN8nDetail || state.showingPlanDetail || activeDiffId != nil
                if !hideJumpButton {
                    Button(action: { openAgentTarget(agent) }) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 322)

            // Right card: agent pills
            CardBackground(wash: nil) {
                AgentPillsView(state: state)
            }
        }
        .onChange(of: state.focusId) { _, new in
            showingN8nDetail = false
            activeDiffId = nil
            withAnimation(.easeIn(duration: 0.16)) { state.showingPlanDetail = false }
        }
        .onChange(of: state.view) { _, v in
            if v != .overview { state.showingPlanDetail = false; activeDiffId = nil }
        }
        .onChange(of: state.mode) { _, m in
            if m != .expanded { state.showingPlanDetail = false; activeDiffId = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
            if let id = activeDiffId {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = nil }
                _ = id
            } else if let task = state.focusTask,
                      let last = state.sessionDiffs[task.id]?.last {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = last.id }
            }
        }
    }

    private func openAgentTarget(_ task: AgentTask?) {
        guard let task else { return }
        switch task.id {
        case "integration_claude":
            if ClaudeHost.activate(task.hostApp) { return }
            let vscodeBundleId = "com.microsoft.VSCode"
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == vscodeBundleId }) {
                app.activate(options: .activateIgnoringOtherApps)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
            }
        case "agent_cursor":
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        case "agent_codex":
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        case "agent_claude-desktop":
            openClaudeDesktopApp()
        case "agent_gemini", "agent_antigravity",
             "agent_copilot", "agent_muse", "agent_opencode", "agent_amp":
            TerminalTarget.activate(sessionBundleId: nil)
        default:
            TerminalTarget.activate(sessionBundleId: task.sessionBundleId)
        }
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing running right now.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Start an agent in your terminal or editor.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#9398A1"))
                }
            }
            .padding(.leading, 118)
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Approval

struct ApprovalView: View {
    @ObservedObject var state: AppState

    var approval: ApprovalInfo? { state.pendingApproval }

    /// The pill, named after the session that asks (several sessions can share a pill).
    private var asker: AgentTask? {
        guard var task = state.focusTask else { return nil }
        if let project = approval?.projectName, !project.isEmpty { task.name = project }
        return task
    }

    var body: some View {
        // Captured when the card is drawn: a click answers the request that was on screen,
        // and is ignored if the card has moved on to the next one since.
        let shownId = approval?.id
        ZStack {
            CardBackground(wash: .amber)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    AgentWho(task: asker, label: "needs permission")
                    // Other requests waiting behind this one: "1/3".
                    if let count = approval?.queueCount, count > 1 {
                        Text(verbatim: "1/\(count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .monospacedDigit()
                    }
                }
                CodeBlock(text: approval?.command ?? approval?.tool ?? "…")
                HStack(spacing: 8) {
                    SecondaryButton("Deny") {
                        HookServer.shared.sendApprovalDecision("deny", for: shownId)
                    }
                    PrimaryButton("Allow") {
                        HookServer.shared.sendApprovalDecision("allow", for: shownId)
                    }
                    // Codex, Copilot CLI and Muse Code do not support updatedPermissions
                    let hideAlways = approval?.pillId == "agent_codex"
                        || approval?.pillId == "agent_copilot"
                        || approval?.pillId == "agent_muse"
                    if !hideAlways {
                        SecondaryButton("Always") {
                            HookServer.shared.sendApprovalDecision("always", for: shownId)
                        }
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Question

struct QuestionView: View {
    @ObservedObject var state: AppState
    @State private var questionIndex = 0
    // Per-question selected labels (empty = none chosen yet)
    @State private var selections: [[String]] = []
    // Per-question custom "Other…" text
    @State private var otherTexts: [String] = []
    // Per-question "Other…" mode active
    @State private var showOther: [Bool] = []
    @FocusState private var otherFieldFocused: Bool

    var question: AskQuestion? { state.pendingQuestion }

    var body: some View {
        ZStack {
            CardBackground(wash: .cyan)
            if let q = question, !q.questions.isEmpty {
                let qi = min(questionIndex, q.questions.count - 1)
                let item = q.questions[qi]
                let isLast = qi == q.questions.count - 1
                let isMulti = item.multiSelect
                let curSel = qi < selections.count ? selections[qi] : []
                let curOther = qi < showOther.count ? showOther[qi] : false
                let curOtherText = qi < otherTexts.count ? otherTexts[qi] : ""
                let canProceed = !curSel.isEmpty || (curOther && !curOtherText.isEmpty)

                VStack(alignment: .leading, spacing: 4) {
                    // Header row: agent name + question counter + "Reply in terminal" link
                    HStack(spacing: 4) {
                        AgentWho(task: nil, label: "Claude Code is asking")
                        Spacer(minLength: 4)
                        if q.questions.count > 1 {
                            Text("\(qi + 1)/\(q.questions.count)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                        Button("Reply in terminal") { HookServer.shared.sendQuestionAsk() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .underline()
                    }
                    // Optional short header label above question text
                    if !item.header.isEmpty {
                        Text(item.header)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    Text(item.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .fixedSize(horizontal: false, vertical: true)
                    // Options (wrapping) or "Other…" compact inline row
                    if curOther {
                        HStack(spacing: 6) {
                            TextField("Your answer…", text: Binding(
                                get: { qi < otherTexts.count ? otherTexts[qi] : "" },
                                set: { v in if qi < otherTexts.count { otherTexts[qi] = v } }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .focused($otherFieldFocused)
                            .onAppear { otherFieldFocused = true }
                            .onSubmit { commitOtherAndProceed(q: q, qi: qi, isLast: isLast) }
                            .onExitCommand { if qi < showOther.count { showOther[qi] = false } }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button(isLast ? "Send" : "Next") {
                                commitOtherAndProceed(q: q, qi: qi, isLast: isLast)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(curOtherText.isEmpty ? Color(hex: "#6B7079") : Color(hex: "#F5F6F8"))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(curOtherText.isEmpty ? 0.05 : 0.15))
                            .clipShape(Capsule())
                            .disabled(curOtherText.isEmpty)
                            Button { if qi < showOther.count { showOther[qi] = false } } label: {
                                Text("✕").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(Color(hex: "#6B7079"))
                        }
                    } else if item.hasDescriptions {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                                let isSelected = curSel.contains(opt.label)
                                Button {
                                    if isMulti {
                                        toggleSelection(qi: qi, label: opt.label)
                                    } else {
                                        selectAndProceed(q: q, qi: qi, label: opt.label, isLast: isLast)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(isSelected ? Color(hex: "#67E8F9") : Color(hex: "#F5F6F8"))
                                        if !opt.description.isEmpty {
                                            Text(opt.description)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color(hex: "#9AA0A8"))
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(isSelected ? Color(hex: "#22D3EE").opacity(0.22) : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color(hex: "#22D3EE").opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                            }
                            SecondaryButton("Other…") {
                                if qi < showOther.count { showOther[qi] = true }
                            }
                        }
                    } else {
                        ChipFlowLayout(spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                                let isSelected = curSel.contains(opt.label)
                                if isMulti {
                                    Button {
                                        toggleSelection(qi: qi, label: opt.label)
                                    } label: {
                                        Text(opt.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(isSelected ? Color(hex: "#22D3EE").opacity(0.22) : Color.white.opacity(0.07))
                                            .foregroundColor(isSelected ? Color(hex: "#67E8F9") : Color(hex: "#C5C8CD"))
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Color(hex: "#22D3EE").opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                                } else {
                                    SecondaryButton(verbatim: opt.label) {
                                        selectAndProceed(q: q, qi: qi, label: opt.label, isLast: isLast)
                                    }
                                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                                }
                            }
                            // "Other…" implicit free-text option
                            SecondaryButton("Other…") {
                                if qi < showOther.count { showOther[qi] = true }
                            }
                        }
                    }
                    // Send/Next — only for multi-select (and not while "Other…" field is open)
                    if isMulti && !curOther {
                        PrimaryButton(isLast ? "Send" : "Next") {
                            proceedFromQuestion(q: q, qi: qi, isLast: isLast)
                        }
                        .disabled(!canProceed)
                        .opacity(canProceed ? 1 : 0.4)
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { resetQuestionState() }
        .onChange(of: state.pendingQuestion) { _, _ in resetQuestionState() }
        .onDisappear { HookServer.shared.releaseQuestionFD() }
    }

    private func resetQuestionState() {
        questionIndex = 0
        let count = state.pendingQuestion?.questions.count ?? 0
        selections = Array(repeating: [], count: count)
        otherTexts = Array(repeating: "", count: count)
        showOther  = Array(repeating: false, count: count)
    }

    private func toggleSelection(qi: Int, label: String) {
        guard qi < selections.count else { return }
        if let i = selections[qi].firstIndex(of: label) {
            selections[qi].remove(at: i)
        } else {
            selections[qi].append(label)
        }
    }

    // Single-select: pick a label and immediately advance/send
    private func selectAndProceed(q: AskQuestion, qi: Int, label: String, isLast: Bool) {
        guard qi < selections.count else { return }
        selections[qi] = [label]
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    // Multi-select Send/Next button
    private func proceedFromQuestion(q: AskQuestion, qi: Int, isLast: Bool) {
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    // "Other…" confirm
    private func commitOtherAndProceed(q: AskQuestion, qi: Int, isLast: Bool) {
        let text = qi < otherTexts.count ? otherTexts[qi] : ""
        guard !text.isEmpty else { return }
        if qi < selections.count { selections[qi] = [text] }
        if isLast {
            sendAnswers(q: q)
        } else {
            if qi < showOther.count { showOther[qi] = false }
            withAnimation { questionIndex = qi + 1 }
        }
    }

    private func sendAnswers(q: AskQuestion) {
        let answers = AskQuestion.buildAnswers(questions: q.questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers)
    }
}

// MARK: - Error

struct ErrorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .red)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "n8n")
                Text("Workflow stopped.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Gmail node timed out after 30s. Retry or open n8n.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#FF8D97"))
                HStack(spacing: 8) {
                    PrimaryButton("Retry") { /* retry */ }
                    SecondaryButton("Open in n8n") { /* open */ }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Brings the Claude desktop app forward (or launches it) — target of the Claude Desktop pill.
private let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

private func openClaudeDesktopApp() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeDesktopBundleId) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

// MARK: - Finished

struct FinishedView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .green)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "Claude Code finished")
                Text({
                    if let fl = state.focusTask?.finalLine { return fl }
                    if let s = state.focusTask?.steps.last(where: { !$0.isDiffStep }) { return s }
                    return String(localized: "Session finished")
                }())
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    if state.focusTask?.id == "agent_claude-desktop" {
                        // Sessions from the Claude desktop app live there, not in a terminal.
                        PrimaryButton("Open Claude") {
                            openClaudeDesktopApp()
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }
                    } else {
                        PrimaryButton("Open terminal") {
                            // The app the session runs in (its terminal, or VS Code), then any known terminal
                            let task = state.focusTask
                            if !(task?.id == "integration_claude" && ClaudeHost.activate(task?.hostApp)),
                               !TerminalTarget.activate(sessionBundleId: task?.sessionBundleId) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                            }
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }
                    }
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Diff Card

struct DiffCardView: View {
    let diff: FileDiff
    let onDismiss: () -> Void

    private var allLines: [DiffLine] { diff.hunks.flatMap { $0.lines } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Button(action: onDismiss) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .medium))
                        Text(diff.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hex: "#F5F6F8"))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 2)
                if diff.added > 0 {
                    Text("+\(diff.added)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#22C55E"))
                }
                if diff.removed > 0 {
                    Text("−\(diff.removed)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#F4505E"))
                }
                Button(action: { openInEditor(diff) }) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(hex: "#5F646D"))
                        .frame(width: 14, height: 14)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            .padding(.bottom, 3)

            // Content
            if diff.tooLarge {
                Text("Diff too large")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else if allLines.isEmpty {
                Text("No changes")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(allLines.enumerated()), id: \.offset) { _, line in
                            DiffLineRowView(line: line)
                        }
                    }
                }
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { onDismiss() }
    }

    private func openInEditor(_ diff: FileDiff) {
        let path = diff.path
        let codePaths = ["/opt/homebrew/bin/code", "/usr/local/bin/code", "/usr/bin/code",
                         "\(NSHomeDirectory())/.nvm/current/bin/code"]
        if let codePath = codePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: codePath)
            // Write: open at line 1; Edit/MultiEdit: open file without line number
            p.arguments = diff.isNewFile ? ["-g", "\(path):1"] : [path]
            try? p.run()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

struct DiffLineRowView: View {
    let line: DiffLine

    private var bgColor: Color {
        switch line.kind {
        case .added:   return Color(hex: "#22C55E").opacity(0.12)
        case .removed: return Color(hex: "#F4505E").opacity(0.12)
        case .context: return Color.clear
        }
    }
    private var fgColor: Color {
        switch line.kind {
        case .added:   return Color(hex: "#86EFAC")
        case .removed: return Color(hex: "#FCA5A5")
        case .context: return Color(hex: "#6B7079")
        }
    }
    private var symbol: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(symbol)
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(line.kind == .added ? Color(hex: "#22C55E") :
                                 line.kind == .removed ? Color(hex: "#F4505E") :
                                 Color(hex: "#454850"))
                .frame(width: 12, alignment: .leading)
            Text(line.text)
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(fgColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(bgColor)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Note (short message, auto-closes)

struct NoteView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.noteMessage ?? "")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, 98)
        }
    }
}

// MARK: - Ticker (overview scrolling task steps) V2

struct TickerView: View {
    let task: AgentTask?
    var onDiffTap: ((Int) -> Void)? = nil

    @State private var rowA: String = "…"   // completed (above, left-shifted)
    @State private var rowB: String = "…"   // current (below) → animates diagonally up-left
    @State private var rowC: String = ""    // incoming current — slides in from below

    @State private var rowAOffset: CGFloat = 0
    @State private var rowAOpacity: Double = 1
    @State private var rowBOffset: CGFloat = 22
    @State private var rowBPhase:  Double  = 0   // 0=current, 1=completed (drives X+scale)
    @State private var rowCOffset: CGFloat = 44
    @State private var rowCOpacity: Double = 0

    @State private var displayIndex: Int = -1
    @State private var isTransitioning = false

    private let completedScale: CGFloat = 11.5 / 13   // 0.885 — matches completed font size

    var steps: [String] {
        let raw = task?.steps ?? []
        return raw.isEmpty ? ["…"] : raw
    }

    var body: some View {
        let isActive = task?.state == .thinking || task?.state == .working
        let rowADiffTap: (() -> Void)? = rowA.parseDiffStep().map { dp in { onDiffTap?(dp.diffId) } }
        let rowBDiffTap: (() -> Void)? = rowB.parseDiffStep().map { dp in { onDiffTap?(dp.diffId) } }

        ZStack(alignment: .topLeading) {
            Color.clear

            // Row A: completed row — always rendered at phase=1 + completedScale
            // Row A never shows its shimmer (phase 1): it doesn't animate one either.
            TickerRowView(text: rowA, phase: 1.0, isActive: isActive, shimmerPaused: true, onDiffTap: rowADiffTap)
                .scaleEffect(completedScale, anchor: .leading)
                .offset(x: -10, y: rowAOffset)
                .opacity(rowAOpacity)

            // Row B: current step → animates diagonally up-left, phase 0→1, scale 1→completedScale
            TickerRowView(text: rowB, phase: rowBPhase, isActive: isActive, onDiffTap: rowBDiffTap)
                .scaleEffect(1 - rowBPhase * (1 - completedScale), anchor: .leading)
                .offset(x: -rowBPhase * 10, y: rowBOffset)

            // Row C: incoming new step — slides in from below at phase=0
            TickerRowView(text: rowC, phase: 0.0, isActive: isActive)
                .offset(y: rowCOffset)
                .opacity(rowCOpacity)
        }
        .frame(height: 44)
        .clipped()
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .onAppear {
            let idx = task?.stepIndex ?? -1
            displayIndex = idx
            if idx >= 0, !steps.isEmpty {
                rowA = idx > 0 ? steps[max(0, idx - 1)] : "…"
                rowB = steps[min(idx, steps.count - 1)]
            }
        }
        .onChange(of: task?.steps.count) { _, _ in
            guard let task, !task.steps.isEmpty, !isTransitioning else { return }
            let newIdx = task.stepIndex
            if displayIndex < 0 {
                displayIndex = newIdx
                rowA = newIdx > 0 ? steps[max(0, newIdx - 1)] : "…"
                rowB = steps[min(newIdx, steps.count - 1)]
                return
            }
            guard newIdx != displayIndex else { return }
            tickerAnimate(to: newIdx)
        }
    }

    private func tickerAnimate(to newIdx: Int) {
        isTransitioning = true
        rowC = steps[min(newIdx, steps.count - 1)]
        rowCOffset = 44
        rowCOpacity = 0

        // Old completed (rowA): fades + slides further up
        withAnimation(.easeOut(duration: 0.28)) {
            rowAOffset  = -22
            rowAOpacity = 0
        }

        // Current (rowB): moves diagonally up-left + shrinks to completed size
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowBOffset = 0
            rowBPhase  = 1
        }

        // New current (rowC): slides in from below
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowCOffset  = 22
            rowCOpacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            self.displayIndex    = newIdx
            self.rowA            = self.rowB
            self.rowAOffset      = 0
            self.rowAOpacity     = 1
            self.rowB            = self.rowC
            self.rowBOffset      = 22
            self.rowBPhase       = 0
            self.rowCOffset      = 44
            self.rowCOpacity     = 0
            self.isTransitioning = false
        }
    }
}

struct TickerRowView: View {
    let text: String
    let phase: Double   // 0 = current (shimmer, large), 1 = completed (dim, scaled down by caller)
    var isActive: Bool = true
    var shimmerPaused: Bool = false
    var onDiffTap: (() -> Void)? = nil

    var body: some View {
        let chevronOpacity:   Double = isActive ? max(0, 1 - phase * 2)       : 0
        let checkmarkOpacity: Double = isActive ? max(0, phase * 2 - 1)       : 1
        let shimmerOpacity:   Double = isActive ? max(0, 1 - phase * 1.6)     : 0
        let staticOpacity:    Double = isActive ? min(1, max(0, phase * 2 - 0.4)) : 1
        let staticColor = (!isActive && phase < 0.5) ? Color(hex: "#C9CDD4") : Color(hex: "#6B7079")

        if let dp = text.parseDiffStep() {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .opacity(chevronOpacity)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(Color(hex: "#454850"))
                        .opacity(checkmarkOpacity)
                }
                .frame(width: 12, alignment: .center)
                // Filename + counts
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        TickerShimmerText(text: dp.filename, paused: shimmerPaused || !isActive)
                            .opacity(shimmerOpacity)
                        Text(dp.filename)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(staticColor)
                            .lineLimit(1).truncationMode(.tail)
                            .opacity(staticOpacity)
                    }
                    if dp.added > 0 {
                        Text(" +\(dp.added)")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(Color(hex: "#22C55E"))
                            .fixedSize()
                    }
                    if dp.removed > 0 {
                        Text(" −\(dp.removed)")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(Color(hex: "#F4505E"))
                            .fixedSize()
                    }
                }
            }
            .frame(height: 22, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onDiffTap?() }
        } else {
            HStack(spacing: 6) {
                // Icon: chevron fades out first half, checkmark fades in second half
                ZStack {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .opacity(chevronOpacity)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(Color(hex: "#454850"))
                        .opacity(checkmarkOpacity)
                }
                .frame(width: 12, alignment: .center)

                // Text: shimmer fades out, dim completed text fades in (overlapping cross-fade)
                ZStack(alignment: .leading) {
                    // An idle task never shows the shimmer (nor row A, see shimmerPaused).
                    TickerShimmerText(text: text, paused: shimmerPaused || !isActive)
                        .opacity(shimmerOpacity)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(staticColor)
                        .lineLimit(1).truncationMode(.tail)
                        .opacity(staticOpacity)
                }
            }
            .frame(height: 22, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TickerShimmerText: View {
    let text: String
    var paused: Bool = false
    @Environment(\.islandViewActive) private var viewActive

    var body: some View {
        // A 2.2 s sweep at display refresh rate. Paused when hidden.
        TimelineView(.animation(paused: paused || !viewActive)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
            // phase sweeps -0.1 → 1.1 so white peak enters from left and exits right
            let phase = p * 1.2 - 0.1
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: Color(hex: "#7c818a"), location: max(0, phase - 0.3)),
                    .init(color: Color(hex: "#F2F3F5"), location: max(0, min(1, phase))),
                    .init(color: Color(hex: "#7c818a"), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
    }
}

// MARK: - Agent pills (overview right card)

struct AgentPillsView: View {
    @ObservedObject var state: AppState
    @State private var swapping = false

    private var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    private var displayTasks: [AgentTask] {
        Array(others.prefix(4))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(displayTasks) { task in
                    Group {
                        AgentPill(task: task, state: state, swapping: $swapping) {
                            swapping = true
                            state.setFocus(task.id)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { swapping = false }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentPill: View {
    let task: AgentTask
    @ObservedObject var state: AppState
    @Binding var swapping: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    private var effectiveColor: String { task.color }

    // The Claude pill shows "VS Code" (or "Claude Code" for a terminal session) regardless of project name
    private var displayName: String {
        task.id == "integration_claude" ? ClaudeHost.pillName(hostApp: task.hostApp) : task.name
    }

    var body: some View {
        Button(action: { onTap() }) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Capsule()
                        .fill(isHovered
                              ? Color(hex: effectiveColor).opacity(0.18)
                              : Color(hex: "#0E0F11"))
                    Capsule()
                        .stroke(Color(hex: effectiveColor).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)
                    HStack(spacing: 0) {
                        AgentAvatarView(task: task)
                            .frame(width: 22 / 0.6, height: 22 / 0.6)
                            .frame(width: 22, height: 22, alignment: .center)
                            .padding(.leading, 8)
                        Spacer()
                    }
                    Text(displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isHovered
                                         ? Color(hex: effectiveColor).lighter(by: 0.3)
                                         : Color(hex: "#6B7079"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .shadow(color: Color(hex: effectiveColor).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)

                // Alert badge (approval / finished / error)
                if let badge = task.pillBadge {
                    PillBadgeView(badge: badge, taskColor: effectiveColor)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

struct PillBadgeView: View {
    let badge: PillBadge
    let taskColor: String

    private var badgeColor: Color {
        switch badge {
        case .approval: return Color(hex: "#F5A524")
        case .finished: return Color(hex: "#22C55E")
        case .error:    return Color(hex: "#F4505E")
        }
    }

    private var icon: String {
        switch badge {
        case .approval: return "exclamationmark"
        case .finished: return "checkmark"
        case .error:    return "xmark"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#0B0C0E"))
                .frame(width: 14, height: 14)
            Circle()
                .fill(badgeColor)
                .frame(width: 12, height: 12)
            Image(systemName: icon)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.black)
        }
        .shadow(color: badgeColor.opacity(0.6), radius: 4, x: 0, y: 0)
    }
}

// MARK: - Column agents (right side of non-overview views)

struct ColumnAgentsView: View {
    @ObservedObject var state: AppState

    var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(others.prefix(4).enumerated()), id: \.1.id) { idx, task in
                AgentAvatarView(task: task)
                    .frame(width: 16 / 0.6, height: 16 / 0.6)
                    .frame(width: 16, height: 16)
                    .position(x: 0, y: CGFloat(50 + idx * 24))
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(idx) * 0.035), value: idx)
            }
        }
    }
}

/// Wrapping horizontal flow layout — used by ModelPickerView and QuestionView.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let r = rows(maxW: proposal.replacingUnspecifiedDimensions().width, subviews: subviews)
        return r.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let r = rows(maxW: bounds.width, subviews: subviews)
        for (idx, pt) in r.placements.enumerated() {
            subviews[idx].place(at: CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y), proposal: .unspecified)
        }
    }
    private func rows(maxW: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [(x: CGFloat, y: CGFloat)]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        var pts: [(x: CGFloat, y: CGFloat)] = []
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            pts.append((x: x, y: y))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: max(maxX, 0), height: y + lineH), pts)
    }
}

// MARK: - Card background

struct CardBackground<Content: View>: View {
    enum Wash { case red, green, pink, amber, cyan, indigo, soft }

    let wash: Wash?
    let content: (() -> Content)?

    init(wash: Wash?, @ViewBuilder content: @escaping () -> Content) {
        self.wash = wash
        self.content = content
    }

    var washColor: Color {
        switch wash {
        case .red:    return Color(hex: "#F4505E").opacity(0.55)
        case .green:  return Color(hex: "#34D399").opacity(0.5)
        case .pink:   return Color(hex: "#F472B6").opacity(0.55)
        case .amber:  return Color(hex: "#F5A524").opacity(0.42)
        case .cyan:   return Color(hex: "#22D3EE").opacity(0.38)
        case .indigo: return Color(hex: "#6366F1").opacity(0.5)
        case .soft:   return Color.white.opacity(0.08)
        case nil:     return Color.clear
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )

            if let content = content {
                content()
            }
        }
    }
}

extension CardBackground where Content == EmptyView {
    init(wash: Wash?) {
        self.wash = wash
        self.content = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        }
    }
}

// MARK: - Shared sub-components

struct AgentWho: View {
    let task: AgentTask?
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            if let task = task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
                Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            }
            Text(LocalizedStringKey(label)).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundColor(Color(hex: "#E8E9EC"))
    }
}



struct ShimmeringText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "#7c818a"), location: 0),
                        .init(color: .white, location: 0.4),
                        .init(color: Color(hex: "#7c818a"), location: 0.7)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0.0

    var body: some View {
        LinearGradient(
            stops: [
                // Clamp all locations to [0,1] and keep them ordered
                .init(color: .clear,                   location: max(0, phase - 0.3)),
                .init(color: Color.white.opacity(0.6), location: max(0, min(1, phase))),
                .init(color: .clear,                   location: min(1, phase + 0.3))
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .blendMode(.overlay)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                phase = 1.3  // travels left→right, exits right edge cleanly
            }
        }
    }
}

// MARK: - Button styles

struct PrimaryButton: View {
    let title: String
    let verbatim: Bool
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = false; self.kbd = kbd; self.action = action
    }

    init(verbatim title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = true; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if verbatim { Text(verbatim: title) } else { Text(LocalizedStringKey(title)) }
                }.font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color(hex: "#F5F6F8"))
            .foregroundColor(Color(hex: "#0B0C0E"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    let verbatim: Bool
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = false; self.kbd = kbd; self.action = action
    }

    init(verbatim title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = true; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if verbatim { Text(verbatim: title) } else { Text(LocalizedStringKey(title)) }
                }.font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color.white.opacity(0.09))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color(hex: "#F5F6F8"))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Settings island view (Point 7)

struct SettingsIslandView: View {
    @ObservedObject var state: AppState

    private var claudeConnected: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return ss.contains { matcher in
            (matcher["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("Bipuu") == true
            } ?? false
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                // Auto-close row
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 16)
                    Text(String(format: String(localized: "Auto-close · %llds"), Int64(state.autoCloseInterval)))
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([10, 15, 30], id: \.self) { s in
                            Button("\(s)s") {
                                state.autoCloseInterval = Double(s)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(state.autoCloseInterval == Double(s) ? Color(hex: "#252830") : Color.clear)
                            .foregroundColor(state.autoCloseInterval == Double(s) ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Connection status
                HStack(spacing: 14) {
                    StatusBadge(label: "Claude Code", ok: claudeConnected)
                    Spacer()
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openFullSettings, object: nil)
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
    }
}

struct StatusBadge: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

// MARK: - Color extension (lighten)

extension Color {
    func lighter(by amount: Double) -> Color {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: min(1, Double(components.redComponent) + amount),
            green: min(1, Double(components.greenComponent) + amount),
            blue: min(1, Double(components.blueComponent) + amount)
        )
    }
}
