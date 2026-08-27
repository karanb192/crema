import SwiftUI
import CremaCore

/// The app's single source of truth. A repeating timer kicks a scan that runs
/// on a background thread (see SessionScanner); its result is published back on
/// the main actor, which applies the power decision and drives the UI.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var decision = decidePower(PowerInputs())
    @Published private(set) var runningBatchRuleIDs: [String] = []
    @Published private(set) var ledger = AppModel.loadLedger()
    @Published var rules: [Rule] = Rule.defaults()

    // User intent.
    @Published private(set) var reviewing = false
    @Published private(set) var pinnedUntil: Date?
    @Published private(set) var pinnedMinutes: Int?     // chosen finite duration, for chip highlight
    @Published private(set) var restNow = false
    @Published private(set) var holdFailed = false      // the OS refused an assertion we wanted

    // Runs off the main actor; only ever entered from a serialized scan, so the
    // unchecked isolation is safe (see `scanning`).
    nonisolated(unsafe) private let scanEngine = SessionScanner()
    private let controller = AssertionController()
    private var timer: Timer?
    private var scanning = false

    private let scanInterval: TimeInterval = 5

    init() {
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Intents

    /// Pin the Mac awake. `minutes == nil` means indefinitely.
    func pin(minutes: Int?) {
        restNow = false
        holdFailed = false
        if let minutes {
            pinnedUntil = Date().addingTimeInterval(Double(minutes) * 60)
            pinnedMinutes = minutes
        } else {
            pinnedUntil = .distantFuture
            pinnedMinutes = nil
        }
        tick()
    }

    func clearPin() {
        pinnedUntil = nil
        pinnedMinutes = nil
        tick()
    }

    func toggleReviewing() {
        reviewing.toggle()
        if reviewing { restNow = false }
        tick()
    }

    func rest() {
        restNow = true
        reviewing = false
        pinnedUntil = nil
        pinnedMinutes = nil
        tick()
    }

    func resume() {
        restNow = false
        tick()
    }

    func setRule(id: String, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        tick()
    }

    // MARK: - The loop

    func tick() {
        // Marketing screenshot mode: fixed hypothetical sessions, no scan, no
        // assertion touched. See DemoMode.
        if DemoMode.enabled {
            sessions = DemoMode.sessions()
            decision = decidePower(DemoMode.inputs())
            runningBatchRuleIDs = []
            return
        }

        // Expire a finite pin (main-actor state) before scheduling the scan.
        if let until = pinnedUntil, until <= Date(), until < .distantFuture {
            pinnedUntil = nil
            pinnedMinutes = nil
        }

        // One scan at a time; a slow scan never stacks up behind the timer.
        guard !scanning else { return }
        scanning = true

        let rules = self.rules
        let intent = SessionScanner.Intent(
            restNow: restNow, pinnedUntil: pinnedUntil, reviewing: reviewing, now: Date()
        )

        Task.detached(priority: .utility) { [weak self, scanEngine] in
            let output = scanEngine.run(rules: rules, intent: intent)
            await MainActor.run {
                guard let self else { return }
                self.holdFailed = !self.controller.apply(output.decision)
                self.sessions = output.sessions
                self.decision = output.decision
                self.runningBatchRuleIDs = output.runningBatchRuleIDs
                self.recordLedger(held: output.decision.systemHold)
                self.scanning = false
            }
        }
    }

    // MARK: - Derived UI state

    var iconSymbol: String {
        if holdFailed { return "exclamationmark.triangle.fill" }
        switch decision.iconState {
        case .working, .holding, .reviewing: return "cup.and.saucer.fill"
        case .idle: return "cup.and.saucer"
        case .suppressed: return "zzz"
        }
    }

    var iconCount: Int? {
        (decision.iconState == .working && decision.workingCount > 0) ? decision.workingCount : nil
    }

    var headline: String {
        if holdFailed {
            return "Could not hold the Mac awake. Check Energy settings or permissions."
        }
        switch decision.iconState {
        case .idle:
            return "Everything is waiting on you. Mac sleeps normally."
        case .working:
            // A batch-rule hold (e.g. ffmpeg) drives .working with zero agents;
            // fall back to its reason instead of "0 agents working".
            if decision.workingCount == 0 {
                return decision.reasons.first.map { "\($0). Mac stays awake." } ?? "Mac stays awake."
            }
            return decision.workingCount == 1
                ? "1 agent working. Mac stays awake."
                : "\(decision.workingCount) agents working. Mac stays awake."
        case .holding:
            return decision.reasons.first ?? "Holding this Mac awake."
        case .reviewing:
            return "Screen on. Mac stays awake, screen won't dim."
        case .suppressed:
            return "Paused. Crema won't keep the Mac awake until you resume."
        }
    }

    var workingCount: Int { sessions.filter(\.isWorking).count }
    var waitingCount: Int { sessions.filter { !$0.isWorking }.count }

    // MARK: - Awake ledger

    private static let ledgerKey = "holdLedger"

    /// One honest, falsifiable line: how long Crema actually held the Mac
    /// awake over the trailing day, and how often it let go. Hidden until an
    /// hour of history exists so it never shows "2 min of the last 2 min".
    var ledgerLine: String? {
        if DemoMode.enabled { return "Awake 2.9 h of the last 10 h · released 14 times" }
        let s = ledger.summary()
        guard s.spanSeconds >= 3600 else { return nil }
        let released = s.releaseCount == 1 ? "released once" : "released \(s.releaseCount) times"
        return "Awake \(Self.hours(s.heldSeconds)) of the last \(Self.hours(s.spanSeconds)) · \(released)"
    }

    private func recordLedger(held: Bool) {
        let before = ledger
        ledger.record(held: held)
        guard ledger != before else { return }
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: Self.ledgerKey)
        }
    }

    private static func loadLedger() -> HoldLedger {
        guard let data = UserDefaults.standard.data(forKey: ledgerKey),
              let stored = try? JSONDecoder().decode(HoldLedger.self, from: data) else {
            return HoldLedger()
        }
        return stored
    }

    private static func hours(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(max(1, Int(seconds / 60))) min"
                       : String(format: "%.1f h", seconds / 3600)
    }
}
