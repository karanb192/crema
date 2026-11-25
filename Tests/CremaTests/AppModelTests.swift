import XCTest
import CremaCore
@testable import Crema

@MainActor
final class AppModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var scanner: BlockingScanner!
    private var controller: TestController!
    private var clock: Date!
    private var model: AppModel!

    override func setUp() async throws {
        suite = "CremaTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        scanner = BlockingScanner()
        controller = TestController()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        model = AppModel(scanEngine: scanner, controller: controller, defaults: defaults,
                         now: { [unowned self] in self.clock }, startsAutomatically: false)
    }

    override func tearDown() async throws {
        scanner.finish()
        await model.scanTask?.value
        defaults.removePersistentDomain(forName: suite)
        model = nil
    }

    func testPauseReleasesImmediatelyAndSurvivesWorkingScan() async {
        model.pin(minutes: nil)
        await scanner.waitUntilStarted()
        XCTAssertTrue(controller.holdsSystem)

        model.rest()
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertEqual(model.decision.iconState, .suppressed)

        await finishScan(workingAgent())
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertFalse(controller.holdsDisplay)
        XCTAssertEqual(model.decision.iconState, .suppressed)
        XCTAssertTrue(model.sessions.first?.isWorking == true)
    }

    func testPinStartsDuringScanAndSurvivesIdleResult() async {
        model.tick()
        await scanner.waitUntilStarted()
        model.pin(minutes: 30)
        XCTAssertTrue(controller.holdsSystem)

        await finishScan()
        XCTAssertTrue(controller.holdsSystem)
        XCTAssertEqual(model.pinnedMinutes, 30)
        XCTAssertEqual(model.decision.iconState, .holding)
    }

    func testClearingPinDuringScanReleasesImmediately() async {
        model.pin(minutes: 30)
        await scanner.waitUntilStarted()
        model.clearPin()
        XCTAssertFalse(controller.holdsSystem)

        await finishScan()
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertNil(model.pinnedUntil)
    }

    func testScreenOffSurvivesScanCompletion() async {
        model.setScreenOn(true)
        await scanner.waitUntilStarted()
        XCTAssertTrue(controller.holdsDisplay)

        model.setScreenOn(false)
        XCTAssertFalse(controller.holdsDisplay)
        XCTAssertFalse(controller.holdsSystem)

        await finishScan()
        XCTAssertFalse(controller.holdsDisplay)
        XCTAssertFalse(controller.holdsSystem)
    }

    func testTimerExpiresAtCompletionTime() async {
        model.pin(minutes: 1)
        await scanner.waitUntilStarted()
        clock = clock.addingTimeInterval(61)

        await finishScan()
        XCTAssertNil(model.pinnedUntil)
        XCTAssertNil(model.pinnedMinutes)
        XCTAssertFalse(controller.holdsSystem)
    }

    func testRuleDisabledDuringScanCannotCreateHold() async {
        model.tick()
        await scanner.waitUntilStarted()
        model.setRule(id: "agent.claude", enabled: false)

        await finishScan(workingAgent())
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertEqual(model.decision.workingCount, 0)
    }

    func testRepeatedControlsKeepOneScanInFlight() async {
        model.tick()
        await scanner.waitUntilStarted()
        model.pin(minutes: 30)
        model.rest()
        model.resume()
        model.setScreenOn(true)
        model.tick()

        await finishScan()
        XCTAssertEqual(scanner.calls, 1)
        XCTAssertTrue(controller.holdsDisplay)
        XCTAssertEqual(model.decision.iconState, .reviewing)
    }

    func testAutomaticHoldKeepsGraceThenReleases() async {
        model.tick()
        await scanner.waitUntilStarted()
        await finishScan(workingAgent())
        XCTAssertEqual(model.decision.iconState, .working)

        clock = clock.addingTimeInterval(5)
        scanner.finish()
        model.tick()
        await model.scanTask?.value
        XCTAssertTrue(controller.holdsSystem)
        XCTAssertEqual(model.decision.iconState, .holding)

        clock = clock.addingTimeInterval(601)
        model.tick()
        await model.scanTask?.value
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertEqual(model.decision.iconState, .idle)
    }

    func testDisablingCachedBatchRuleReleasesImmediately() async {
        model.tick()
        await scanner.waitUntilStarted()
        let process = ScannedProcess(pid: 43, ppid: 1, name: "ffmpeg", cpuNanos: 0,
                                     startTime: clock, cwd: "")
        await finishScan(.init(processes: [process]))
        XCTAssertTrue(controller.holdsSystem)

        model.setRule(id: "batch.ffmpeg", enabled: false)
        XCTAssertFalse(controller.holdsSystem)
        await model.scanTask?.value
        XCTAssertFalse(controller.holdsSystem)
        XCTAssertEqual(model.runningBatchRuleIDs, ["batch.ffmpeg"])
    }

    func testFailedAssertionDoesNotCountAsHeld() async {
        controller.refuseHold = true
        model.pin(minutes: 30)
        await scanner.waitUntilStarted()

        await finishScan()
        XCTAssertTrue(model.holdFailed)
        XCTAssertTrue(model.decision.systemHold)
        XCTAssertFalse(controller.holdsSystem)
        clock = clock.addingTimeInterval(120)
        XCTAssertEqual(model.ledger.summary(now: clock).heldSeconds, 0)
    }

    private func finishScan(_ output: SessionScanner.Output = .init()) async {
        let task = model.scanTask
        scanner.finish(output)
        await task?.value
    }

    private func workingAgent() -> SessionScanner.Output {
        let process = ScannedProcess(pid: 42, ppid: 1, name: "claude", cpuNanos: 0,
                                     startTime: clock, cwd: "/tmp/example-project")
        return .init(processes: [process], workingPIDs: [42], lastActive: [42: clock])
    }
}

private final class TestController: PowerControlling {
    var holdsSystem = false
    var holdsDisplay = false
    var refuseHold = false

    func apply(_ decision: PowerDecision) -> Bool {
        holdsSystem = decision.systemHold && !refuseHold
        holdsDisplay = decision.displayHold && !refuseHold
        return !refuseHold || (!decision.systemHold && !decision.displayHold)
    }
}

private final class BlockingScanner: SessionScanning {
    private let condition = NSCondition()
    private let started = XCTestExpectation(description: "scan started")
    private var output: SessionScanner.Output?
    private(set) var calls = 0

    func run(rules: [Rule], now: Date) -> SessionScanner.Output {
        condition.lock()
        defer { condition.unlock() }
        calls += 1
        started.fulfill()
        while output == nil { condition.wait() }
        return output!
    }

    func waitUntilStarted() async {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(result, .completed)
    }

    func finish(_ result: SessionScanner.Output = .init()) {
        condition.lock()
        defer { condition.unlock() }
        output = result
        condition.broadcast()
    }
}

final class SessionScannerHelperTests: XCTestCase {
    func testRecognizesClaudeHelpers() {
        func helper(_ args: [String]) -> Bool {
            SessionScanner.isClaudeHelper(args, executableName: "2.1.332")
        }
        XCTAssertTrue(helper(["/usr/local/bin/claude", "daemon", "run"]))
        XCTAssertTrue(helper(["claude bg-pty-host", "--bg-pty-host", "/tmp/x.sock"]))
        XCTAssertTrue(helper(["claude bg-spare", "--bg-spare", "/tmp/y.sock"]))
        XCTAssertTrue(helper(["ugrep", "-G", "--ignore-files"]))
        XCTAssertFalse(helper(["claude", "--output-format", "stream-json"]))
        XCTAssertFalse(helper(["/Users/me/.local/share/claude/versions/2.1.332", "--resume"]))
        XCTAssertFalse(helper([]))
    }

    func testReadsClaudeSessionIDFromArguments() {
        XCTAssertEqual(SessionScanner.claudeSessionID(["claude", "--session-id=abc"]), "abc")
        XCTAssertEqual(SessionScanner.claudeSessionID(["claude", "--resume", "def", "--verbose"]), "def")
        XCTAssertNil(SessionScanner.claudeSessionID(["claude", "--resume", "--verbose"]))
        XCTAssertNil(SessionScanner.claudeSessionID(["claude"]))
    }

    func testRecognizesCodexSupervisor() {
        XCTAssertTrue(SessionScanner.isCodexHelper(["/x/codex", "app-server", "daemon", "pid-update-loop"]))
        XCTAssertFalse(SessionScanner.isCodexHelper(["/x/codex", "app-server", "--listen", "unix://"]))
        XCTAssertFalse(SessionScanner.isCodexHelper(["codex"]))
    }

    func testFindsHostAppAmongAncestors() {
        func proc(_ pid: pid_t, _ ppid: pid_t, _ path: String) -> ScannedProcess {
            ScannedProcess(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path,
                           cpuNanos: 0, startTime: Date(), cwd: "")
        }
        let app = proc(10, 1, "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)")
        let shell = proc(11, 10, "/bin/zsh")
        let agent = proc(12, 11, "/usr/local/bin/claude")
        let daemon = proc(13, 1, "/usr/local/bin/claude")
        let byPID = Dictionary(uniqueKeysWithValues: [app, shell, agent, daemon].map { ($0.pid, $0) })
        XCTAssertEqual(SessionScanner.hostApp(of: agent, in: byPID), "T3 Code (Nightly)")
        XCTAssertNil(SessionScanner.hostApp(of: daemon, in: byPID))
    }
}

final class FolderLabelTests: XCTestCase {
    func label(_ folder: String) -> String {
        AgentSession(pid: 1, ppid: 0, ruleID: "r", processName: "claude", displayName: "Claude Code",
                     folder: folder, isWorking: false, startedAt: Date(), lastActive: Date()).folderLabel
    }

    func testCleansT3Folders() {
        XCTAssertEqual(label("/Users/me/.t3/worktrees/coloring/t3-f9dac1b0-b7e814c026d9e928"), "coloring (worktree)")
        XCTAssertEqual(label("/Users/me/.t3/scratch/2026-11-25-check-if-crema-code-can-5c2ecd38"), "check if crema code can")
    }

    func testUsesProjectNameElsewhere() {
        XCTAssertEqual(label("/Users/me/Documents/projects/experiments/coloring"), "coloring")
        XCTAssertEqual(label(""), "")
    }
}
