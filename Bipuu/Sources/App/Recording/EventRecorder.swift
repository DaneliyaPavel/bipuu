import Foundation
import BipuuCore
import BipuuSQLite

/// Writes normalised hook events and the sessions behind them into the local database.
///
/// Recording is strictly off the hook path: `submit` only places the item on a bounded queue and
/// returns (microseconds); a single background consumer does the database work. It can never delay
/// or change what the agent sees. If the database cannot be opened (for example it was written by a
/// newer Bipuu) recording switches itself off for the rest of the run and the app carries on.
final class EventRecorder: Sendable {
    private enum Message: Sendable {
        case hook(RecordedHook)
        case flush(CheckedContinuation<Void, Never>)
    }

    /// Items waiting for the consumer. Past this, the oldest are dropped (and counted).
    static let queueLimit = 1_024

    private let continuation: AsyncStream<Message>.Continuation
    private let consumer: Task<Void, Never>
    private let counters = Counters()

    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var _dropped = 0, _failed = 0, _recorded = 0
        var dropped: Int { lock.withLock { _dropped } }
        var failed: Int { lock.withLock { _failed } }
        var recorded: Int { lock.withLock { _recorded } }
        func drop() { lock.withLock { _dropped += 1 } }
        func fail() { lock.withLock { _failed += 1 } }
        func record() { lock.withLock { _recorded += 1 } }
    }

    /// `databasePath` is opened lazily on the first item, so starting the app never waits for the disk.
    /// `onWrite` is called on the consumer's thread after each event is stored (used to refresh the work view).
    /// With an `inference` policy, a session seen for the first time is proposed a task (see `TaskInferrer`).
    /// `inference` and `retention` are asked each time they matter (a new session, a prune), so a change
    /// in Settings applies to the next event. `nil` switches the feature off. The history is pruned after the
    /// first write and then every `pruneEvery` events.
    init(databasePath: String, inference: @escaping @Sendable () -> InferencePolicy? = { nil },
         retention: @escaping @Sendable () -> RetentionPolicy? = { nil }, pruneEvery: Int = 500,
         onWrite: (@Sendable () -> Void)? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .bufferingNewest(Self.queueLimit))
        self.continuation = continuation
        let counters = counters
        consumer = Task.detached(priority: .utility) {
            var sink: Sink?
            var disabled = false
            for await message in stream {
                switch message {
                case .flush(let done): done.resume()
                case .hook(let item):
                    guard !disabled else { continue }
                    do {
                        if sink == nil { sink = try Sink(path: databasePath, inference: inference, retention: retention, pruneEvery: pruneEvery, log: log) }
                        try await sink?.write(item)
                        counters.record()
                        onWrite?()
                    } catch {
                        counters.fail()
                        if sink == nil {
                            disabled = true
                            log("Event recording disabled: cannot open the database (\(Self.describe(error)))")
                        } else {
                            log("Event recording failed for one event (\(Self.describe(error)))")
                        }
                    }
                }
            }
            await sink?.close()
        }
    }

    deinit { continuation.finish() }

    /// Never blocks, never throws.
    func submit(_ item: RecordedHook) {
        settle(continuation.yield(.hook(item)))
    }

    /// Waits until everything submitted before this call has been written. For tests and shutdown.
    func flush() async {
        await withCheckedContinuation { c in
            let result = continuation.yield(.flush(c))
            if case .terminated = result { c.resume() }   // already stopped: nothing to wait for
            settle(result)
        }
    }

    /// Finishes the queue and waits for the consumer (closes the database).
    func stop() async {
        continuation.finish()
        await consumer.value
    }

    /// The queue is bounded and keeps the newest: a full queue pushes its oldest item out. That item is
    /// counted if it was an event, and released if it was somebody waiting in `flush()`.
    private func settle(_ result: AsyncStream<Message>.Continuation.YieldResult) {
        guard case .dropped(let old) = result else { return }
        switch old {
        case .hook: counters.drop()
        case .flush(let waiting): waiting.resume()
        }
    }

    var droppedCount: Int { counters.dropped }
    var failedCount: Int { counters.failed }
    var recordedCount: Int { counters.recorded }

    // MARK: Default location

    /// The recorder the app runs with: the standard database, and the user's choices from Settings
    /// (task inference, retention) read fresh whenever they matter.
    static func standard(supportDir: URL, onWrite: (@Sendable () -> Void)? = nil,
                         log: @escaping @Sendable (String) -> Void) -> EventRecorder {
        EventRecorder(databasePath: defaultDatabasePath(supportDir: supportDir),
                      inference: { HistorySettings.inferencePolicy() },
                      retention: { HistorySettings.retentionPolicy() },
                      onWrite: onWrite, log: log)
    }

    /// `BIPUU_EVENT_DB` overrides the path (used by the end-to-end script so it never touches real data).
    static func defaultDatabasePath(supportDir: URL) -> String {
        if let p = ProcessInfo.processInfo.environment["BIPUU_EVENT_DB"], !p.isEmpty { return p }
        return supportDir.appendingPathComponent("bipuu.sqlite").path
    }

    /// Names only: never put event content into a log line.
    private static func describe(_ error: Error) -> String {
        if let e = error as? SQLiteStoreError {
            switch e {
            case .unsupportedDatabaseVersion(let f, let s): return "database version \(f) is newer than supported \(s)"
            case .database(let code, _): return "sqlite code \(code)"
            case .corruptedEvent, .corruptedRecord: return "stored data is inconsistent"
            case .closed: return "closed"
            }
        }
        return String(describing: type(of: error))
    }

    // MARK: Consumer state

    /// Owns the two stores and the "already saved" caches. Used only by the consumer task.
    private actor Sink {
        private let events: SQLiteEventStore
        private let domain: SQLiteDomainStore
        private let inference: @Sendable () -> InferencePolicy?
        private let retention: @Sendable () -> RetentionPolicy?
        private let pruneEvery: Int
        private var written = 0
        private let log: @Sendable (String) -> Void
        private var agents = Set<AgentID>(), hosts = Set<HostID>(), sessions = Set<SessionID>()

        init(path: String, inference: @escaping @Sendable () -> InferencePolicy?, retention: @escaping @Sendable () -> RetentionPolicy?,
             pruneEvery: Int, log: @escaping @Sendable (String) -> Void) throws {
            self.log = log; self.inference = inference; self.retention = retention; self.pruneEvery = max(1, pruneEvery)
            // Create the file ourselves, owner-only, before SQLite does: its WAL files inherit the mode.
            if !FileManager.default.fileExists(atPath: path) {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let events = try SQLiteEventStore(path: path)
            let domain = try SQLiteDomainStore(path: path)
            self.events = events
            self.domain = domain
        }

        func write(_ item: RecordedHook) async throws {
            let id = item.identity
            if !agents.contains(id.agent.id) { try await domain.save(id.agent); agents.insert(id.agent.id) }
            if let host = id.host, !hosts.contains(host.id) { try await domain.save(host); hosts.insert(host.id) }
            try await ensureSession(id, startedAt: item.event.occurredAt, now: item.event.occurredAt)
            if item.event.kind == .sessionEnded, var s = try await domain.session(id.sessionID), s.endedAt == nil {
                s.endedAt = item.event.occurredAt     // read-modify-write keeps any task assignment
                try await domain.save(s)
            }
            // An event carries the attribution that was current when it was recorded; later
            // reassignments never rewrite it.
            var event = item.event
            if let taskID = try await domain.session(id.sessionID)?.taskID {
                event.taskID = taskID
                event.projectID = try await domain.task(taskID)?.projectID
            }
            _ = try await events.append(event)
            written += 1
            if written == 1 || written % pruneEvery == 0 { await prune() }
        }

        /// Applies the retention policy as it is now. A failure is logged and never stops recording.
        private func prune() async {
            guard let policy = retention() else { return }
            do {
                let result = try await events.prune(policy, now: Date())
                if result.removed > 0 { log("History pruned: \(result.removed) event(s) removed") }
            } catch {
                log("History pruning failed (\(String(describing: type(of: error))))")
            }
        }

        /// Creates the session on first sight; never overwrites one that exists (it may have a task by now).
        private func ensureSession(_ id: HookIdentity, startedAt: Date, now: Date) async throws {
            guard !sessions.contains(id.sessionID) else { return }
            if try await domain.session(id.sessionID) == nil {
                try await domain.save(Session(id: id.sessionID, agentID: id.agent.id, hostID: id.host?.id,
                                              workingDirectory: id.workingDirectory, externalRef: id.externalRef,
                                              startedAt: startedAt))
                // Only a brand-new session is proposed a task: one that already exists (assigned, or
                // detached by the user) is never revisited, so inference cannot undo a user's choice.
                if let policy = inference() {
                    let inferrer = TaskInferrer(domain: domain, events: events, locator: GitWorkContextLocator(), policy: policy)
                    do { _ = try await inferrer.place(session: id.sessionID, at: now) }
                    catch { log("Task inference failed for a new session (\(String(describing: type(of: error))))") }
                }
            }
            sessions.insert(id.sessionID)
        }

        func close() async {
            await events.close(); await domain.close()
        }
    }
}
