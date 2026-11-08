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

    /// The scanner's CPU reading must match the kernel's own accounting in
    /// real units. Raw Mach ticks read about 41x low on Apple Silicon, and a
    /// flipped ratio would read about 1700x high; both fall outside the band.
    func testOwnCPUMatchesKernelAccounting() {
        let me = getpid()
        func scanned() -> UInt64 { ProcessScanner.info(for: me)?.cpuNanos ?? 0 }
        func kernel() -> UInt64 {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func nanos(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1_000 }
            return nanos(usage.ru_utime) + nanos(usage.ru_stime)
        }
        let scannedBefore = scanned(), kernelBefore = kernel()
        let threadStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var x: UInt64 = 0
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - threadStart < 300_000_000 { x &+= 1 }
        XCTAssertGreaterThan(x, 0)
        let scannedDelta = Double(scanned() - scannedBefore)
        let kernelDelta = Double(kernel() - kernelBefore)
        XCTAssertGreaterThan(kernelDelta, 250_000_000)
        XCTAssertEqual(scannedDelta / kernelDelta, 1, accuracy: 0.25)
    }

    /// CPU of a child that already exited and was reaped shows up in the
    /// parent's reaped total, in the same units the kernel reports.
    func testReapedChildCPUMatchesKernelAccounting() throws {
        let me = getpid()
        func scanned() -> UInt64 { ProcessScanner.info(for: me)?.childCPUNanos ?? 0 }
        func kernel() -> UInt64 {
            var usage = rusage()
            getrusage(RUSAGE_CHILDREN, &usage)
            func nanos(_ t: timeval) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_usec) * 1_000 }
            return nanos(usage.ru_utime) + nanos(usage.ru_stime)
        }
        let scannedBefore = scanned(), kernelBefore = kernel()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done"]
        try child.run()
        child.waitUntilExit()
        let scannedDelta = Double(scanned() - scannedBefore)
        let kernelDelta = Double(kernel() - kernelBefore)
        XCTAssertGreaterThan(kernelDelta, 100_000_000)
        XCTAssertEqual(scannedDelta / kernelDelta, 1, accuracy: 0.25)
    }
}
