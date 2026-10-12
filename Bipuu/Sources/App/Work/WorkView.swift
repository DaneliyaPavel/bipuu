import SwiftUI

extension WorkModel {
    /// The app's model, reading the same database the recorder writes.
    static let shared = WorkModel(databasePath: { EventRecorder.defaultDatabasePath(supportDir: HookServer.supportDir) })
}

/// The island's work view: what is going on across projects, tasks and sessions.
struct WorkView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var model = WorkModel.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            content
                .padding(.leading, 98).padding(.trailing, 16).padding(.vertical, 8)
        }
        .onAppear { model.viewDidAppear() }
        .onDisappear { model.viewDidDisappear() }
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .ready:
            WorkOverviewList(overview: model.overview, now: model.now,
                             onConfirm: { model.confirm($0) }, onRename: { model.rename($0, to: $1) })
        case .notLoaded:
            Color.clear
        case .noDatabase:
            message(String(localized: "work.off.title", defaultValue: "Nothing recorded yet"),
                    String(localized: "work.off.hint", defaultValue: "Work appears after an agent session reports to Bipuu."))
        case .failed:
            message(String(localized: "work.failed.title", defaultValue: "Can't read recorded work"),
                    String(localized: "work.failed.hint", defaultValue: "Agents are not affected. See the Bipuu log."))
        }
    }

    private func message(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            Text(hint).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
