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

    func testEncodesNonASCIIPerUTF16Unit() {
        // An emoji is two UTF-16 units, so two dashes, as Claude Code's JS does.
        XCTAssertEqual(SessionActivityProbe.encodeProjectPath("/a/\u{1F600}b"), "-a---b")
        XCTAssertEqual(SessionActivityProbe.encodeProjectPath("/a/é"), "-a--")
    }

    func testReadsClaudeSessionFile() throws {
        let root = NSTemporaryDirectory() + "crema-sessions-\(getpid())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let json = #"{"pid":4242,"sessionId":"s1","name":"Crema Agents","status":"busy","entrypoint":"t3-code","cwd":"/p","startedAt":1795000000500}"#
        try json.write(toFile: root + "/4242.json", atomically: true, encoding: .utf8)

        let probe = SessionActivityProbe(projectsRoot: root, sessionsRoot: root)
        let info = try XCTUnwrap(probe.claudeSession(pid: 4242, processStart: start))
        XCTAssertEqual(info.sessionID, "s1")
        XCTAssertEqual(info.name, "Crema Agents")
        XCTAssertEqual(info.isBusy, true)
        XCTAssertEqual(info.hostName, "T3 Code")
        XCTAssertEqual(info.cwd, "/p")
        XCTAssertNil(probe.claudeSession(pid: 1, processStart: start))
    }

    func testIgnoresSessionFileFromEarlierProcessWithSamePID() throws {
        let root = NSTemporaryDirectory() + "crema-sessions-stale-\(getpid())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try #"{"pid":7,"status":"busy","startedAt":1795000000000}"#
            .write(toFile: root + "/7.json", atomically: true, encoding: .utf8)
        let probe = SessionActivityProbe(projectsRoot: root, sessionsRoot: root)
        XCTAssertNotNil(probe.claudeSession(pid: 7, processStart: Date(timeIntervalSince1970: 1_795_000_002)))
        // Written late on a slow launch: still this process's record.
        XCTAssertNotNil(probe.claudeSession(pid: 7, processStart: Date(timeIntervalSince1970: 1_794_999_992)))
        XCTAssertNil(probe.claudeSession(pid: 7, processStart: Date(timeIntervalSince1970: 1_795_003_600)))
    }
}

final class ClaudeTurnSignalTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let written = Date(timeIntervalSince1970: 1_999_990)

    func testRunningJobBeatsIdle() {
        XCTAssertEqual(ClaudeTurnSignal.lastActive(hasRunningJob: true, isBusy: false,
                                                   sessionTranscript: nil, directoryTranscript: nil, now: now), now)
    }

    func testStatusBeatsTranscripts() {
        XCTAssertNil(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: false,
                                                 sessionTranscript: { self.written },
                                                 directoryTranscript: { self.written }, now: now))
        XCTAssertEqual(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: true,
                                                   sessionTranscript: nil, directoryTranscript: nil, now: now), now)
    }

    func testSessionTranscriptThenDirectoryFallback() {
        XCTAssertEqual(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: nil,
                                                   sessionTranscript: { self.written },
                                                   directoryTranscript: { nil }, now: now), written)
        // A stale session transcript does not hide a newer folder write.
        XCTAssertEqual(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: nil,
                                                   sessionTranscript: { .distantPast },
                                                   directoryTranscript: { self.written }, now: now), written)
        // A stale session id (after /clear) falls back to the folder.
        XCTAssertEqual(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: nil,
                                                   sessionTranscript: { nil },
                                                   directoryTranscript: { self.written }, now: now), written)
        // A shared folder passes no directory lookup.
        XCTAssertNil(ClaudeTurnSignal.lastActive(hasRunningJob: false, isBusy: nil,
                                                 sessionTranscript: { nil }, directoryTranscript: nil, now: now))
    }
}
