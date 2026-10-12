import Foundation
import SwiftUI
import BipuuCore
import BipuuSQLite

extension Notification.Name {
    /// Posted (from any thread) after the recorder wrote something. The work view refreshes on it, only while visible.
    static let workDataChanged = Notification.Name("bipuu.workDataChanged")
}

/// Reads and edits the work overview. Owns its own connections to the same database the recorder writes
/// (WAL allows it) and opens them only when the view is first shown; it never creates the database.
@MainActor
final class WorkModel: ObservableObject {
    /// Where the database lives; injected so the model does not depend on the app's socket server.
    private let databasePath: @MainActor () -> String

    init(databasePath: @escaping @MainActor () -> String) { self.databasePath = databasePath }

    enum Status: Equatable { case notLoaded, noDatabase, ready, failed(String) }

    @Published private(set) var overview = WorkOverview(groups: [], unattachedSessionCount: 0, hiddenTaskCount: 0)
    @Published private(set) var status: Status = .notLoaded
    @Published private(set) var now = Date()

    private var visible = false
    private var pending: Task<Void, Never>?
    private var source: Source?
    private var observer: (any NSObjectProtocol)?

    /// The view appeared: load now, and follow the recorder while it stays on screen.
    func viewDidAppear() {
        visible = true
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .workDataChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
        refreshNow()
    }

    /// The view went away: stop listening, so a hidden island does no work at all.
    func viewDidDisappear() {
        visible = false
        pending?.cancel(); pending = nil
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    func confirm(_ id: TaskID) { act { try await $0.confirm(id) } }
    func rename(_ id: TaskID, to title: String) { act { try await $0.rename(id, to: title) } }

    // MARK: Refresh

    private func scheduleRefresh() {
        guard visible, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))      // a burst of events becomes one reload
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let src = try self.openSource()
                guard let src else { self.status = .noDatabase; return }
                let result = try await src.overview()
                guard self.visible else { return }
                self.overview = result; self.now = Date(); self.status = .ready
            } catch {
                self.status = .failed(String(describing: type(of: error)))
            }
        }
    }

    private func act(_ body: @escaping @Sendable (Source) async throws -> Void) {
        Task { [weak self] in
            guard let self, let src = try? self.openSource() else { return }
            do { try await body(src) } catch { self.status = .failed(String(describing: type(of: error))) }
            self.refreshNow()
        }
    }

    private func openSource() throws -> Source? {
        if let source { return source }
        let path = databasePath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let made = try Source(path: path)
        source = made
        return made
    }

    /// The two stores, behind one actor. Used by the model only.
    private actor Source {
        private let domain: SQLiteDomainStore
        private let events: SQLiteEventStore
        private let inferrer: TaskInferrer

        init(path: String) throws {
            let d = try SQLiteDomainStore(path: path), e = try SQLiteEventStore(path: path)
            domain = d; events = e
            inferrer = TaskInferrer(domain: d, events: e, locator: GitWorkContextLocator())
        }

        func overview() async throws -> WorkOverview {
            try await WorkOverviewBuilder(domain: domain, events: events).build()
        }

        func confirm(_ id: TaskID) async throws { try await inferrer.confirm(task: id, at: Date()) }

        /// Renaming a proposal also confirms it (typing a name is accepting the task); renaming a task you own just renames it.
        func rename(_ id: TaskID, to title: String) async throws {
            let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !clean.isEmpty, var task = try await domain.task(id) else { return }
            if task.origin == .inferred { try await inferrer.confirm(task: id, title: clean, at: Date()); return }
            task.title = clean; task.updatedAt = Date()
            try await domain.save(task)
        }
    }
}
