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

    func testTicksConvertToNanosecondsOnAppleSiliconTimebase() {
        // 24 ticks of 125/3 ns each is exactly 1000 ns.
        XCTAssertEqual(ProcessScanner.nanos(fromTicks: 24, numer: 125, denom: 3), 1_000)
        XCTAssertEqual(ProcessScanner.nanos(fromTicks: 24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(ProcessScanner.nanos(fromTicks: 1_234, numer: 1, denom: 1), 1_234)
    }

    func testOwnBusyLoopReadsAsRealCPUTime() {
        // Regression: raw ticks made a fully busy process read ~41x too low,
        // so the CPU signal never crossed the working threshold.
        let me = getpid()
        func cpu() -> UInt64 { ProcessScanner.info(for: me)?.cpuNanos ?? 0 }
        let before = cpu()
        let start = Date()
        var x: UInt64 = 0
        while Date().timeIntervalSince(start) < 0.5 { x &+= 1 }
        XCTAssertGreaterThan(x, 0)
        let used = Double(cpu() - before) / 1_000_000_000
        XCTAssertGreaterThan(used, 0.3, "a 0.5s busy loop must read as roughly 0.5s of CPU")
    }
}
