import XCTest
@testable import CremaCore

final class HoldLedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testConsecutiveStatesCollapse() {
        var ledger = HoldLedger()
        ledger.record(held: true, at: at(0))
        ledger.record(held: true, at: at(5))
        XCTAssertEqual(ledger.events.count, 1)
    }

    func testHeldTimeIncludesOngoingHold() {
        var ledger = HoldLedger()
        ledger.record(held: true, at: at(0))
        let s = ledger.summary(now: at(90))
        XCTAssertEqual(s.heldSeconds, 90 * 60, accuracy: 1)
        XCTAssertEqual(s.spanSeconds, 90 * 60, accuracy: 1)
        XCTAssertEqual(s.releaseCount, 0)
    }

    func testHeldTimeAndReleasesAcrossTransitions() {
        var ledger = HoldLedger()
        ledger.record(held: true, at: at(0))
        ledger.record(held: false, at: at(60))    // release 1 after 1h held
        ledger.record(held: true, at: at(120))
        ledger.record(held: false, at: at(150))   // release 2 after 30m held
        let s = ledger.summary(now: at(600))
        XCTAssertEqual(s.heldSeconds, 90 * 60, accuracy: 1)
        XCTAssertEqual(s.spanSeconds, 600 * 60, accuracy: 1)
        XCTAssertEqual(s.releaseCount, 2)
    }

    func testLeadingReleaseIsNotCounted() {
        var ledger = HoldLedger()
        ledger.record(held: false, at: at(0))
        ledger.record(held: true, at: at(10))
        let s = ledger.summary(now: at(20))
        XCTAssertEqual(s.releaseCount, 0)
        XCTAssertEqual(s.heldSeconds, 10 * 60, accuracy: 1)
    }

    func testPruneClampsToWindow() {
        var ledger = HoldLedger()
        ledger.window = 60 * 60   // 1h window for the test
        ledger.record(held: true, at: at(0))
        ledger.record(held: false, at: at(30))
        ledger.record(held: true, at: at(200))    // prunes: cutoff is 140
        let s = ledger.summary(now: at(200))
        XCTAssertEqual(s.spanSeconds, 60 * 60, accuracy: 1)
        XCTAssertEqual(s.heldSeconds, 0, accuracy: 1, "pre-window held time must not leak in")
    }

    func testRoundTripsThroughCodable() throws {
        var ledger = HoldLedger()
        ledger.record(held: true, at: at(0))
        ledger.record(held: false, at: at(60))
        let data = try JSONEncoder().encode(ledger)
        let back = try JSONDecoder().decode(HoldLedger.self, from: data)
        XCTAssertEqual(back, ledger)
    }
}
