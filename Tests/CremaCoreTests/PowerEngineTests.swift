import XCTest
@testable import CremaCore

/// The precedence ladder is the heart of the app, so it gets the most tests.
final class PowerEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNothingActiveSleepsNormally() {
        let d = decidePower(PowerInputs(now: now))
        XCTAssertFalse(d.systemHold)
        XCTAssertFalse(d.displayHold)
        XCTAssertEqual(d.iconState, .idle)
    }

    func testAgentsWorkingHoldSystem() {
        let d = decidePower(PowerInputs(agentHolds: ["Claude Code (2 working)"],
                                        workingCount: 2, now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertFalse(d.displayHold)
        XCTAssertEqual(d.iconState, .working)
        XCTAssertEqual(d.workingCount, 2)
    }

    func testReviewingHoldsDisplayToo() {
        let d = decidePower(PowerInputs(reviewing: true, now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertTrue(d.displayHold)
        XCTAssertEqual(d.iconState, .reviewing)
    }

    func testPinAloneHolds() {
        let d = decidePower(PowerInputs(pinnedUntil: now.addingTimeInterval(1800), now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertFalse(d.displayHold)
        XCTAssertEqual(d.iconState, .holding)
    }

    func testExpiredPinDoesNotHold() {
        let d = decidePower(PowerInputs(pinnedUntil: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(d.systemHold)
        XCTAssertEqual(d.iconState, .idle)
    }

    func testBatchProcessRunHolds() {
        let d = decidePower(PowerInputs(processHolds: ["ffmpeg running"], now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertEqual(d.iconState, .working)
    }

    /// The user asked for this explicitly: a pin must survive every agent going idle.
    func testPinSurvivesAgentsFinishing() {
        let d = decidePower(PowerInputs(pinnedUntil: .distantFuture, agentHolds: [], now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertEqual(d.iconState, .holding)
    }

    /// Rest now sits at the top of the ladder and beats everything below it.
    func testRestNowOverridesEverything() {
        let d = decidePower(PowerInputs(
            restNow: true,
            pinnedUntil: .distantFuture,
            reviewing: true,
            agentHolds: ["Claude Code (5 working)"],
            processHolds: ["ffmpeg running"],
            workingCount: 5,
            now: now
        ))
        XCTAssertFalse(d.systemHold)
        XCTAssertFalse(d.displayHold)
        XCTAssertEqual(d.iconState, .suppressed)
    }

    func testGraceHoldsAfterAgentsFinish() {
        let d = decidePower(PowerInputs(graceActive: true, now: now))
        XCTAssertTrue(d.systemHold)
        XCTAssertEqual(d.iconState, .holding)
        XCTAssertEqual(d.reasons.first, "Agents just finished, resting soon")
    }

    func testRestNowBeatsGrace() {
        let d = decidePower(PowerInputs(restNow: true, graceActive: true, now: now))
        XCTAssertFalse(d.systemHold)
        XCTAssertEqual(d.iconState, .suppressed)
    }

    func testInfinitePinReasonReads() {
        let d = decidePower(PowerInputs(pinnedUntil: .distantFuture, now: now))
        XCTAssertEqual(d.reasons.first, "Pinned awake")
    }

    func testFinitePinReasonReadsMinutes() {
        let d = decidePower(PowerInputs(pinnedUntil: now.addingTimeInterval(3600), now: now))
        XCTAssertEqual(d.reasons.first, "Pinned for 60 min")
    }
}
