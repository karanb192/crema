import Foundation
import SQLite3

/// Thread titles from T3 Code's local state database, keyed by the agent's own
/// session id (Claude's `--session-id`). T3 records that id as the
/// `nativeThreadRef.nativeId` of each provider thread.
///
/// The schema is T3's private one, so every failure (no T3, a renamed table, a
/// locked file) returns no titles and the row falls back to its folder.
public struct T3ThreadTitles {
    private let databasePath: String

    public init(databasePath: String = ("~/.t3/userdata/statev2.sqlite" as NSString).expandingTildeInPath) {
        self.databasePath = databasePath
    }

    public func titles(forSessionIDs ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: databasePath) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT json_extract(pt.payload_json, '$.nativeThreadRef.nativeId'), t.title
            FROM orchestration_v2_projection_provider_threads pt
            JOIN orchestration_v2_projection_threads t ON t.thread_id = pt.thread_id
            WHERE json_extract(pt.payload_json, '$.nativeThreadRef.nativeId') IN (\(placeholders))
              AND t.deleted_at IS NULL
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient)
        }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let titleText = sqlite3_column_text(statement, 1) else { continue }
            let title = String(cString: titleText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { result[String(cString: idText)] = title }
        }
        return result
    }
}
