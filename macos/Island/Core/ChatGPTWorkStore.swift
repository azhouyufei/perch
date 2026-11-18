import Foundation
import SQLite3

/// Work chats use ChatGPT conversation IDs, not the executor's CODEX_THREAD_ID.
/// Only read metadata explicitly marked as Work; ordinary personal chats stay out.
enum ChatGPTWorkStore {
    struct Chat {
        let id: String, title: String, created: Date, updated: Date
        let active: Bool
    }

    static func chats(in root: URL, now: Date) -> [Chat] {
        let url = root.appendingPathComponent("sqlite/codex.db")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return CodexThreadStore.readOnly(url) { db in
            var active = Set<String>()
            var statement: OpaquePointer?
            // Missing/stale activity means unknown, never completed.
            if sqlite3_prepare_v2(db, "SELECT thread_id,observed_at_ms FROM active_chat_turns", -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let age = now.timeIntervalSince1970 - sqlite3_column_double(statement, 1) / 1000
                    if (-5...120).contains(age), let id = text(statement, 0) { active.insert(id) }
                }
            }
            sqlite3_finalize(statement); statement = nil
            defer { sqlite3_finalize(statement) }
            let sql = """
                SELECT c.thread_id,c.display_title,c.source_created_at,
                       max(c.source_updated_at,c.source_recency_at)
                FROM local_thread_catalog c
                JOIN local_thread_catalog_hosts h ON c.host_id=h.host_id
                WHERE h.host_kind='chatgpt' AND c.source_kind='chatgpt'
                  AND c.conversation_origin='tpp' AND c.missing_candidate=0
                ORDER BY max(c.source_updated_at,c.source_recency_at) DESC
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            var chats: [Chat] = [], seen = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0), UUID(uuidString: id) != nil, seen.insert(id).inserted else { continue }
                let title = text(statement, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let updated = sqlite3_column_double(statement, 3)
                guard updated.isFinite, updated > 0 else { continue }
                chats.append(Chat(id: id, title: title.isEmpty ? "ChatGPT Work" : String(title.prefix(400)),
                    created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    updated: Date(timeIntervalSince1970: updated), active: active.contains(id)))
            }
            return chats
        } ?? []
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
