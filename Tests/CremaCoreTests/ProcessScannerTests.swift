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
        func scanned() -> UInt64 { ProcessScanner.cpu(for: me)?.own ?? 0 }
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
        func scanned() -> UInt64 { ProcessScanner.cpu(for: me)?.reaped ?? 0 }
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

    func testReadsChildArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertEqual(ProcessScanner.commandLine(for: child.processIdentifier).arguments, ["/bin/sleep", "30"])
    }

    func testParsesProcArgsBufferKeepingOnlyRequestedEnvironment() {
        func buffer(argc: Int32, _ strings: [String], padding: Int = 3) -> [UInt8] {
            var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
            bytes += Array("/usr/local/bin/claude".utf8) + [0] + Array(repeating: 0, count: padding)
            for string in strings { bytes += Array(string.utf8) + [0] }
            return bytes + [0]
        }
        let parsed = ProcessScanner.parseProcArgs(
            buffer(argc: 2, ["claude", "--resume", "CLAUDE_CONFIG_DIR=/x/.claude-work", "TOKEN=secret", "A=b=c"]),
            environmentKeys: ["CLAUDE_CONFIG_DIR", "A"])
        XCTAssertEqual(parsed.arguments, ["claude", "--resume"])
        XCTAssertEqual(parsed.environment, ["CLAUDE_CONFIG_DIR": "/x/.claude-work", "A": "b=c"])

        XCTAssertTrue(ProcessScanner.parseProcArgs(buffer(argc: 1, ["claude", "TOKEN=secret"]),
                                                   environmentKeys: []).environment.isEmpty)
        XCTAssertEqual(ProcessScanner.parseProcArgs([1, 0], environmentKeys: []).arguments, [])
    }

    func testReadsCPUOnlyForRequestedTreesAndTheirChildren() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }

        let me = getpid()
        let sleeper = child.processIdentifier
        let scanner = ProcessScanner()
        for _ in 0..<2 {   // the second scan uses cached identities
            // The test process and its child: CPU for both.
            let all = scanner.snapshot(readingCPUOf: { $0.pid == me })
            XCTAssertTrue(try XCTUnwrap(all.first { $0.pid == me }).hasCPU)
            XCTAssertGreaterThan(try XCTUnwrap(all.first { $0.pid == me }).cpuNanos, 0)
            let child = try XCTUnwrap(all.first { $0.pid == sleeper })
            XCTAssertTrue(child.hasCPU, "a descendant of a requested process gets CPU too")
            XCTAssertEqual(child.path, "/bin/sleep")

            // Only the child: its parent, the test process, gets none.
            let some = scanner.snapshot(readingCPUOf: { $0.pid == sleeper })
            let mine = try XCTUnwrap(some.first { $0.pid == me })
            XCTAssertFalse(mine.hasCPU)
            XCTAssertEqual(mine.cpuNanos, 0)
            XCTAssertTrue(try XCTUnwrap(some.first { $0.pid == sleeper }).hasCPU)
        }
    }

    func testRereadsPathOnceAfterTheExecWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        // Read inside the first 2 s: once more after the window, then final.
        XCTAssertFalse(ProcessScanner.needsPathRefresh(startTime: start, pathReadAt: start.addingTimeInterval(0.5),
                                                       now: start.addingTimeInterval(1)))
        XCTAssertTrue(ProcessScanner.needsPathRefresh(startTime: start, pathReadAt: start.addingTimeInterval(0.5),
                                                      now: start.addingTimeInterval(5)))
        XCTAssertFalse(ProcessScanner.needsPathRefresh(startTime: start, pathReadAt: start.addingTimeInterval(5),
                                                       now: start.addingTimeInterval(60)))
    }

    func testByteSubstringSearch() {
        XCTAssertTrue(ScannedProcess.utf8("ffmpeg-static", contains: "ffmpeg"))
        XCTAssertFalse(ScannedProcess.utf8("x", contains: ""), "an empty pattern matches nothing")
        XCTAssertFalse(ScannedProcess.utf8("ff", contains: "ffmpeg"))
        XCTAssertFalse(ScannedProcess.utf8("", contains: "a"))
        XCTAssertTrue(ScannedProcess.utf8("café-claude", contains: "claude"))
    }

}
