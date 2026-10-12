import Foundation
import SQLite3
import BipuuChecking
import BipuuCore
import BipuuSQLite

// MARK: helpers (raw access to the database file, independent of the store under test)

func tempDB() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("bipuu-\(UUID().uuidString).sqlite").path
}
func removeDB(_ path: String) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}
func withDB<T>(_ path: String, _ body: (OpaquePointer) throws -> T) rethrows -> T {
    var db: OpaquePointer?
    precondition(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    return try body(db!)
}
func sql(_ path: String, _ statement: String) {
    withDB(path) { db in precondition(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, statement) }
}
func scalarText(_ path: String, _ query: String) -> String? {
    withDB(path) { db in
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, query, -1, &s, nil); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let p = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: p)
    }
}
func names(_ path: String, type: String) -> Set<String> {
    withDB(path) { db in
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='\(type)'", -1, &s, nil); defer { sqlite3_finalize(s) }
        var out = Set<String>()
        while sqlite3_step(s) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(s, 0))) }
        return out
    }
}
func ev(_ id: String, occ: Double = 1, rec: Double? = nil, session: String = "s", task: String? = nil,
        kind: EventKind = .notice, schema: Int = AgentEvent.currentSchemaVersion,
        payload: JSONValue = .object([:])) -> AgentEvent {
    EventStoreContract.ev(id, occ: occ, rec: rec, session: session, task: task, kind: kind, schema: schema, payload: payload)
}
nonisolated(unsafe) var tempPaths: [String] = []

// MARK: 1. the shared contract

await EventStoreContract.runAll("SQLiteEventStore") {
    // Each contract test gets its own database file. Files are left in the temp dir only until
    // the process ends; removed below.
    let path = tempDB()
    tempPaths.append(path)
    return try SQLiteEventStore(path: path)
}

// MARK: 2. SQLite-specific behaviour

await run("migration v0 -> v1 creates table, indexes, version, WAL") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    try await check(scalarText(path, "PRAGMA user_version") == "1")
    try await check(scalarText(path, "PRAGMA journal_mode") == "wal")
    try await check(names(path, type: "table").contains("events"))
    try await check(names(path, type: "index").isSuperset(of: ["idx_events_session", "idx_events_task", "idx_events_recent"]))
    await s.close()
}

await run("reopen retains events, order and duplicate detection") {
    let path = tempDB(); defer { removeDB(path) }
    let events = (0..<20).map { ev("e\($0)", occ: Double(20 - $0), session: $0 % 2 == 0 ? "A" : "B", task: "T") }
    do {
        let s = try SQLiteEventStore(path: path)
        for e in events { _ = try await s.append(e) }
        await s.close()
    }
    let s = try SQLiteEventStore(path: path)
    let expected = events.sorted(by: AgentEvent.canonicalOrder)
    try await check(try await s.events(forTask: TaskID("T")) == expected)
    try await check(try await s.append(events[3]) == .duplicate)
    try await checkThrows(EventStoreError.eventIDCollision(EventID("e3"))) {
        _ = try await s.append(ev("e3", occ: 99, session: "A", task: "T"))
    }
}

await run("committed events are durable without close(); second connection sees them") {
    let path = tempDB(); defer { removeDB(path) }
    let first = try SQLiteEventStore(path: path)       // never closed: simulates an abrupt exit
    _ = try await first.append(ev("durable"))
    let second = try SQLiteEventStore(path: path)
    try await check(try await second.recentEvents(limit: 5).map(\.id.rawValue) == ["durable"])
}

await run("database from a newer build is rejected and left untouched") {
    let path = tempDB(); defer { removeDB(path) }
    sql(path, "PRAGMA user_version = 99; CREATE TABLE marker(x);")
    try await checkThrows(SQLiteEventStoreError.unsupportedDatabaseVersion(found: 99, supported: 1)) {
        _ = try SQLiteEventStore(path: path)
    }
    try await check(scalarText(path, "PRAGMA user_version") == "99")
    try await check(names(path, type: "table") == ["marker"])     // no events table, nothing downgraded
}

await run("corrupted raw_json is an explicit error, never silent loss") {
    for garbage in ["x'7B7D'", "x'FFFE00'", "x''"] {
        let path = tempDB(); defer { removeDB(path) }
        let s = try SQLiteEventStore(path: path)
        _ = try await s.append(ev("good", occ: 1))
        _ = try await s.append(ev("bad", occ: 2))
        sql(path, "UPDATE events SET raw_json = \(garbage) WHERE event_id = 'bad'")
        for query in [{ try await s.events(forSession: SessionID("s")) }, { try await s.recentEvents(limit: 10) }] {
            do { _ = try await query(); try await check(false, "expected corruption error for \(garbage)") }
            catch let e as SQLiteEventStoreError {
                if case .corruptedEvent(let id, _) = e { try await check(id == "bad") } else { try await check(false, "\(e)") }
            }
        }
        await s.close()
    }
}

await run("indexed columns that contradict the stored envelope are detected") {
    let mutations = ["session_id = 'other'", "occurred_at_us = occurred_at_us + 1", "event_kind = 'tool.started'",
                     "task_id = 'ghost'", "schema_version = 7", "source = 'impostor'", "agent_id = 'x'"]
    for m in mutations {
        let path = tempDB(); defer { removeDB(path) }
        let s = try SQLiteEventStore(path: path)
        _ = try await s.append(ev("e", task: "T"))
        sql(path, "UPDATE events SET \(m) WHERE event_id = 'e'")
        do { _ = try await s.recentEvents(limit: 5); try await check(false, "no error for \(m)") }
        catch let e as SQLiteEventStoreError {
            if case .corruptedEvent = e { try await check(true) } else { try await check(false, "\(e)") }
        }
        await s.close()
    }
}

await run("a rejected append leaves the database unchanged (transaction rolled back)") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    _ = try await s.append(ev("a", payload: .object(["v": .number(1)])))
    for i in 0..<3 {
        try await checkThrows(EventStoreError.eventIDCollision(EventID("a"))) {
            _ = try await s.append(ev("a", payload: .object(["v": .number(Double(i + 2))])))
        }
    }
    try await check(scalarText(path, "SELECT count(*) FROM events") == "1")
    try await check(try await s.append(ev("b")) == .appended)     // the connection is still usable
}

await run("closed store fails explicitly; close is idempotent") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    await s.close(); await s.close()
    try await checkThrows(SQLiteEventStoreError.closed) { _ = try await s.append(ev("x")) }
    try await checkThrows(SQLiteEventStoreError.closed) { _ = try await s.recentEvents(limit: 1) }
}

await run("concurrent appends are all stored once") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<200 {
            group.addTask { _ = try await s.append(ev("c\(i % 150)", occ: Double(i % 150))) }   // 50 identical duplicates
        }
        try await group.waitForAll()
    }
    try await check(scalarText(path, "SELECT count(*) FROM events") == "150")
}

await run("queries use the indexes (no full scans)") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    _ = try await s.append(ev("x", task: "T"))
    func plan(_ q: String) -> String {
        withDB(path) { db in
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + q, -1, &st, nil); defer { sqlite3_finalize(st) }
            var out = ""
            while sqlite3_step(st) == SQLITE_ROW { out += String(cString: sqlite3_column_text(st, 3)) + ";" }
            return out
        }
    }
    let order = "ORDER BY occurred_at_us, received_at_us, event_id"
    let p1 = plan("SELECT * FROM events WHERE session_id = 's' \(order)")
    let p2 = plan("SELECT * FROM events WHERE task_id = 'T' \(order)")
    let p3 = plan("SELECT * FROM events ORDER BY occurred_at_us DESC, received_at_us DESC, event_id DESC LIMIT 5")
    try await check(p1.contains("idx_events_session") && !p1.contains("TEMP B-TREE"), p1)
    try await check(p2.contains("idx_events_task") && !p2.contains("TEMP B-TREE"), p2)
    try await check(p3.contains("idx_events_recent") && !p3.contains("TEMP B-TREE"), p3)
}

await run("sanity: 10k appends, recent and per-session queries scale roughly linearly") {
    let path = tempDB(); defer { removeDB(path) }
    let s = try SQLiteEventStore(path: path)
    func now() -> Double { Date().timeIntervalSince1970 }
    var batchTimes: [Double] = []
    for batch in 0..<2 {
        let t0 = now()
        for i in (batch * 5_000)..<((batch + 1) * 5_000) {
            _ = try await s.append(ev("e\(i)", occ: Double(i), session: "s\(i % 100)", task: i % 7 == 0 ? "T" : nil))
        }
        batchTimes.append(now() - t0)
    }
    let t1 = now()
    let recent = try await s.recentEvents(limit: 50)
    let one = try await s.events(forSession: SessionID("s42"))
    let queryTime = now() - t1
    try await check(recent.count == 50 && recent.last?.id.rawValue == "e9999")
    try await check(one.count == 100)
    // Not an SLA: only catches pathological (quadratic) behaviour. The second 5k must not cost 3x the first.
    try await check(batchTimes[1] < batchTimes[0] * 3 + 0.5, "batches \(batchTimes)")
    try await check(queryTime < 2.0, "queries \(queryTime)s")
    print("      (5k appends: \(String(format: "%.2f", batchTimes[0]))s then \(String(format: "%.2f", batchTimes[1]))s; queries \(String(format: "%.3f", queryTime))s)")
}

for p in tempPaths { removeDB(p) }
finish()
