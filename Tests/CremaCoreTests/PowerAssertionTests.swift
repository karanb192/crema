import XCTest
@testable import CremaCore

/// These are integration tests: they create real IOKit assertions and confirm
/// the OS actually registered them, which is the whole point of the app.
final class PowerAssertionTests: XCTestCase {

    func testStartStopIsIdempotent() {
        let assertion = PowerAssertion(kind: .systemSleep)
        XCTAssertFalse(assertion.isActive)

        XCTAssertTrue(assertion.start(reason: "Crema unit test"))
        XCTAssertTrue(assertion.isActive)
        // Starting again while active is a no-op that still reports success.
        XCTAssertTrue(assertion.start(reason: "Crema unit test"))

        assertion.stop()
        XCTAssertFalse(assertion.isActive)
        assertion.stop()   // double stop is safe
        XCTAssertFalse(assertion.isActive)
    }

    /// Create an assertion with a unique reason, then confirm the OS lists it
    /// via `pmset -g assertions`. Proves the hold is real, not just a flag.
    func testAssertionRegistersWithSystem() throws {
        let reason = "Crema-test-\(getpid())"
        let assertion = PowerAssertion(kind: .systemSleep)
        XCTAssertTrue(assertion.start(reason: reason))
        defer { assertion.stop() }

        let listing = try pmsetAssertions()
        XCTAssertTrue(listing.contains(reason),
                      "pmset did not list our assertion reason:\n\(listing)")
    }

    func testDisplayAssertionType() {
        let assertion = PowerAssertion(kind: .displaySleep)
        XCTAssertTrue(assertion.start(reason: "Crema display test"))
        XCTAssertTrue(assertion.isActive)
        assertion.stop()
    }

    // MARK: - Helper

    private func pmsetAssertions() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
