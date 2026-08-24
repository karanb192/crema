import XCTest
@testable import CremaCore

/// Integration tests against the live process table.
final class ProcessScannerTests: XCTestCase {

    func testSnapshotFindsRunningProcesses() {
        let processes = ProcessScanner().snapshot()
        XCTAssertFalse(processes.isEmpty, "the process table should never be empty")
    }

    func testSnapshotIncludesSelf() {
        let me = getpid()
        let processes = ProcessScanner().snapshot()
        let selfProc = processes.first { $0.pid == me }
        let found = try? XCTUnwrap(selfProc)
        XCTAssertNotNil(found)
        XCTAssertFalse(found?.name.isEmpty ?? true)
        XCTAssertLessThanOrEqual(found?.startTime ?? .distantFuture, Date())
    }

    func testCurrentDirectoryIsReadable() {
        // Our own process cwd must resolve; anything unreadable returns "".
        let cwd = ProcessScanner.cwd(for: getpid())
        XCTAssertFalse(cwd.isEmpty, "own-process cwd should be readable when unsandboxed")
        XCTAssertTrue(cwd.hasPrefix("/"))
    }
}
