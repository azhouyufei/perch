import Foundation
import SQLite3

/// Codex Desktop can retain a thread in its paginated SQLite history after removing its rollout.
final class CodexThreadStore {
    struct Thread {
        let id: String, cwd: String, source: String
        let name: String?, title: String?, branch: String?, project: String?
        let updated: Date, created: Date
        var digest: SessionDigest
    }
    struct Index {
        var visible: [String: Thread] = [:]
        var hidden = Set<String>()
    }

    private struct Stamp: Equatable {
        let path: String, size: Int?, modified: Date?
        init(_ url: URL) {
            path = url.path
            let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = info?.fileSize; modified = info?.contentModificationDate
        }
    }

    private let lock = NSLock()
    private var cached: (files: [Stamp], index: Index)?

    static func databases(in root: URL) -> (state: URL?, history: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        func newest(_ prefix: String) -> URL? {
            files.compactMap { url -> (Int, URL)? in
                let name = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "sqlite", name.hasPrefix(prefix),
                      let version = Int(name.dropFirst(prefix.count)) else { return nil }
                return (version, url)
            }.max { $0.0 < $1.0 }?.1
        }
        return (newest("state_"), newest("thread_history_"))
    }

    func index(in root: URL) -> Index {
        let (state, history) = Self.databases(in: root)
        guard let state else { return Index() }
        let files = [state, history].compactMap { $0 }.flatMap { [Stamp($0), Stamp(URL(fileURLWithPath: $0.path + "-wal"))] }
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.files == files { return cached.index }
        guard var index = Self.readOnly(state, query: Self.readThreads) else { return cached?.index ?? Index() }
        if let history {
            let metadata = index
            guard let hydrated = Self.readOnly(history, query: { db -> Index? in
                var result = metadata
                return Self.readLatestTurns(db, into: &result) ? result : nil
            }) else { return metadata }
            index = hydrated
        }
        cached = (files, index)
        return index
    }

    /// A checkpointed WAL database in a read-only directory may have no shared-memory sidecar.
    /// Prefer SQLite's locking reader. Only use a stable, journal-free file for the immutable fallback.
    static func readOnly<T>(_ url: URL, query: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection = db,
           sqlite3_exec(connection, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK {
            defer { sqlite3_close(connection) }
            return query(connection)
        }
        sqlite3_close(db); db = nil
        let sidecars = ["-wal", "-journal"].map { url.path + $0 }
        func checkpointed() -> Bool { sidecars.allSatisfy { !FileManager.default.fileExists(atPath: $0) } }
        let before = Stamp(url)
        guard checkpointed(), var uri = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        uri.query = "mode=ro&immutable=1"
        guard let path = uri.string else { return nil }
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db, let result = query(db), checkpointed(), Stamp(url) == before else { return nil }
        return result
    }

    private static func text(_ s: OpaquePointer?, _ col: Int32) -> String? {
        guard let bytes = sqlite3_column_text(s, col) else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }
    private static func projects(in db: OpaquePointer?) -> (names: [String: String], roots: [(String, String)]) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT p.id,p.name,r.path FROM projects p LEFT JOIN project_roots r ON p.id=r.project_id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ([:], []) }
        var names: [String: String] = [:], roots: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let name = text(statement, 1) else { continue }
            names[id] = name
            if let path = text(statement, 2), path.hasPrefix("/") {
                roots.append((URL(fileURLWithPath: path).standardizedFileURL.path, name))
            }
        }
        return (names, roots.sorted { $0.0.count > $1.0.count })
    }

    private static func readThreads(_ db: OpaquePointer) -> Index? {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        var fields = Set<String>()
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &s, nil) == SQLITE_OK else { return nil }
        while sqlite3_step(s) == SQLITE_ROW { if let name = text(s, 1) { fields.insert(name) } }
        sqlite3_finalize(s); s = nil
        func optional(_ field: String) -> String { fields.contains(field) ? field : "NULL" }
        let catalog = projects(in: db)
        let sql = """
            SELECT id, source, archived, cwd, updated_at, created_at, substr(\(optional("name")),1,400),
              substr(\(optional("title")),1,400), \(optional("git_branch")), \(optional("thread_source")), \(optional("originator")), \(optional("project_id"))
            FROM threads
            """
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        var index = Index()
        var result = sqlite3_step(s)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(s) }
            guard let id = text(s, 0) else { continue }
            guard sqlite3_column_int(s, 2) == 0, let source = text(s, 1), ["vscode", "cli"].contains(source),
                  text(s, 10) != "codex_exec", text(s, 9) != "subagent" else { index.hidden.insert(id); continue }
            guard let cwd = text(s, 3) else { continue }
            let updated = Date(timeIntervalSince1970: sqlite3_column_double(s, 4))
            let created = Date(timeIntervalSince1970: sqlite3_column_double(s, 5))
            let project = text(s, 11).flatMap { catalog.names[$0] } ?? catalog.roots.first {
                cwd == $0.0 || cwd.hasPrefix($0.0 == "/" ? "/" : $0.0 + "/")
            }?.1
            let terminal = ["codex-tui", "codex_cli_rs"].contains(text(s, 10) ?? "")
            index.visible[id] = Thread(id: id, cwd: cwd, source: terminal ? "cli" : source, name: text(s, 6), title: text(s, 7),
                                      branch: text(s, 8), project: project, updated: updated, created: created, digest: SessionDigest())
        }
        return result == SQLITE_DONE ? index : nil
    }

    /// Both joins use the thread/turn/item primary key. No tool payloads or attachment data leave SQLite.
    private static func readLatestTurns(_ db: OpaquePointer, into index: inout Index) -> Bool {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        let sql = """
            SELECT t.status, coalesce(t.completed_at,t.started_at),
              (SELECT substr(group_concat(substr(json_extract(value,'$.text'),1,6000),char(10)),1,6000)
                 FROM json_each(u.item_json,'$.content') WHERE json_extract(value,'$.type')='text'),
              substr(json_extract(a.item_json,'$.text'),1,6000), t.turn_id
            FROM thread_turns t
            LEFT JOIN thread_items u ON u.thread_id=t.thread_id AND u.turn_id=t.turn_id AND u.item_id=t.first_user_item_id AND u.item_type='userMessage'
            LEFT JOIN thread_items a ON a.thread_id=t.thread_id AND a.turn_id=t.turn_id AND a.item_id=t.final_agent_item_id AND a.item_type='agentMessage'
            WHERE t.thread_id=? ORDER BY t.rollout_ordinal DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
        for id in Array(index.visible.keys) {
            let status = id.withCString { bytes -> Int32 in
                sqlite3_bind_text(s, 1, bytes, -1, nil)
                defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
                let result = sqlite3_step(s)
                guard result == SQLITE_ROW else { return result }
                var digest = SessionDigest()
                digest.lastTimestamp = Date(timeIntervalSince1970: sqlite3_column_double(s, 1))
                digest.lastUserFull = text(s, 2).flatMap { TranscriptParser.text(from: $0, keepLines: true) }
                digest.lastUserText = digest.lastUserFull
                digest.lastAssistantFull = text(s, 3)
                digest.lastAssistantText = digest.lastAssistantFull
                digest.lastRole = digest.lastAssistantFull != nil ? "assistant" : digest.lastUserFull != nil ? "user" : nil
                digest.turnId = text(s, 4)
                digest.turnOpen = text(s, 0) == "inProgress"
                digest.interrupted = text(s, 0) == "interrupted"
                if text(s, 0) == "failed" { digest.failed = "The last turn failed." }
                index.visible[id]?.digest = digest
                return result
            }
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { return false }
        }
        return true
    }
}
