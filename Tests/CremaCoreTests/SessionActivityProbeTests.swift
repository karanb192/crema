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
        let when = probe.lastWrite(processName: "claude", cwd: cwd)
        XCTAssertNotNil(when)
        XCTAssertLessThanOrEqual(abs(when!.timeIntervalSinceNow), 5)
    }

    func testNonClaudeProcessHasNoFileSignal() {
        let probe = SessionActivityProbe(projectsRoot: NSTemporaryDirectory())
        XCTAssertNil(probe.lastWrite(processName: "codex", cwd: "/Users/test/proj"))
    }

    func testMissingDirectoryReturnsNil() {
        let probe = SessionActivityProbe(projectsRoot: NSTemporaryDirectory() + "nope-\(getpid())")
        XCTAssertNil(probe.lastWrite(processName: "claude", cwd: "/Users/test/proj"))
    }
}
