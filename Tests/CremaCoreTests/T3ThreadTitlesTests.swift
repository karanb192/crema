import XCTest
import SQLite3
@testable import CremaCore

final class T3ThreadTitlesTests: XCTestCase {

    func testMatchesTitleBySessionID() throws {
        let path = NSTemporaryDirectory() + "crema-t3-\(getpid()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, title TEXT, deleted_at TEXT);
            CREATE TABLE orchestration_v2_projection_provider_threads (thread_id TEXT, payload_json TEXT);
            INSERT INTO orchestration_v2_projection_threads VALUES ('t1', 'Crema Agents', NULL), ('t2', 'Gone', '2026-01-01');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES
              ('t1', '{"nativeThreadRef":{"nativeId":"s1"}}'),
              ('t2', '{"nativeThreadRef":{"nativeId":"s2"}}');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let titles = T3ThreadTitles(databasePath: path).titles(forSessionIDs: ["s1", "s2", "s3"])
        XCTAssertEqual(titles, ["s1": "Crema Agents"])
    }

    func testMissingOrForeignDatabaseYieldsNoTitles() throws {
        XCTAssertEqual(T3ThreadTitles(databasePath: "/nonexistent/x.sqlite").titles(forSessionIDs: ["s1"]), [:])

        let path = NSTemporaryDirectory() + "crema-t3-empty-\(getpid()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_close(db)
        XCTAssertEqual(T3ThreadTitles(databasePath: path).titles(forSessionIDs: ["s1"]), [:])
    }
}
