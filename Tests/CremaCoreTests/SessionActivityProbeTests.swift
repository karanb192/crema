import XCTest
@testable import CremaCore

final class SessionActivityProbeTests: XCTestCase {

    func testFindsNewestTranscriptForClaudeCwd() throws {
        let root = NSTemporaryDirectory() + "crema-probe-\(getpid())"
        let cwd = "/Users/test/some/project"
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = root + "/" + encoded
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        try "{}".write(toFile: dir + "/session.jsonl", atomically: true, encoding: .utf8)

        let probe = SessionActivityProbe(projectsRoot: root)
        let when = probe.lastClaudeWrite(cwd: cwd)
        XCTAssertNotNil(when)
        XCTAssertLessThanOrEqual(abs(when!.timeIntervalSinceNow), 5)
    }

    func testEmptyCwdHasNoFileSignal() {
        let probe = SessionActivityProbe(projectsRoot: NSTemporaryDirectory())
        XCTAssertNil(probe.lastClaudeWrite(cwd: ""))
    }

    func testMissingDirectoryReturnsNil() {
        let probe = SessionActivityProbe(projectsRoot: NSTemporaryDirectory() + "nope-\(getpid())")
        XCTAssertNil(probe.lastClaudeWrite(cwd: "/Users/test/proj"))
    }

    func testEncodesProjectPathLikeClaudeCode() {
        XCTAssertEqual(SessionActivityProbe.encodeProjectPath("/Users/me/.t3/scratch/my_app"),
                       "-Users-me--t3-scratch-my-app")
        XCTAssertEqual(SessionActivityProbe.encodeProjectPath("/Users/me/My Project"),
                       "-Users-me-My-Project")
    }

    func testFindsTranscriptForDottedCwd() throws {
        let root = NSTemporaryDirectory() + "crema-probe-dot-\(getpid())"
        let dir = root + "/-Users-test--t3-proj"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "{}".write(toFile: dir + "/abc.jsonl", atomically: true, encoding: .utf8)

        let probe = SessionActivityProbe(projectsRoot: root)
        XCTAssertNotNil(probe.lastClaudeWrite(cwd: "/Users/test/.t3/proj"))
        XCTAssertNotNil(probe.lastClaudeWrite(cwd: "/Users/test/.t3/proj", sessionID: "abc"))
        XCTAssertNil(probe.lastClaudeWrite(cwd: "/Users/test/.t3/proj", sessionID: "other"))
    }

    func testReadsClaudeSessionFile() throws {
        let root = NSTemporaryDirectory() + "crema-sessions-\(getpid())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let json = #"{"pid":4242,"sessionId":"s1","name":"Crema Agents","status":"busy","entrypoint":"t3-code"}"#
        try json.write(toFile: root + "/4242.json", atomically: true, encoding: .utf8)
        try json.write(toFile: root + "/999.json", atomically: true, encoding: .utf8)  // stale pid

        let probe = SessionActivityProbe(projectsRoot: root, sessionsRoot: root)
        let info = try XCTUnwrap(probe.claudeSession(pid: 4242))
        XCTAssertEqual(info.sessionID, "s1")
        XCTAssertEqual(info.name, "Crema Agents")
        XCTAssertEqual(info.isBusy, true)
        XCTAssertEqual(info.hostName, "T3 Code")
        XCTAssertNil(probe.claudeSession(pid: 999))
        XCTAssertNil(probe.claudeSession(pid: 1))
    }
}
