import SwiftUI
import CremaCore

/// The app's single source of truth. Runs the scan loop every few seconds,
/// folds process state and user intent through the CremaCore engine, applies
/// the resulting power decision, and publishes everything the UI draws.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var decision = decidePower(PowerInputs())
    @Published var rules: [Rule] = Rule.defaults()

    // User intent, in precedence order below the ladder in CremaCore.
    @Published private(set) var reviewing = false
    @Published private(set) var pinnedUntil: Date?
    @Published private(set) var restNow = false

    private let scanner = ProcessScanner()
    private let detector = TurnDetector()
    private let engine = RuleEngine()
    private let controller = AssertionController()
    private let activity = SessionActivityProbe()
    private var timer: Timer?

    private let scanInterval: TimeInterval = 5
    /// How long to keep holding after the last agent turn ends.
    private let graceSeconds: TimeInterval = 600
    private var lastAgentWorkingAt: Date?

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
        pinnedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        tick()
    }

    func clearPin() {
        pinnedUntil = nil
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
        let now = Date()

        // Expire a finite pin.
        if let until = pinnedUntil, until <= now, until < .distantFuture {
            pinnedUntil = nil
        }

        let processes = scanner.snapshot()
        let working = detector.update(processes: processes, now: now) { [activity] proc in
            activity.lastWrite(processName: proc.name, cwd: proc.cwd)
        }
        let result = engine.evaluate(rules: rules, processes: processes, workingPIDs: working)

        sessions = engine.sessions(
            rules: rules, processes: processes, workingPIDs: working,
            lastActive: { [detector] pid in detector.lastActive(for: pid) }
        )

        // Grace: keep holding for a while after the last agent turn ends.
        if result.workingSessionCount > 0 { lastAgentWorkingAt = now }
        let graceActive: Bool = {
            guard result.agentHolds.isEmpty, let last = lastAgentWorkingAt else { return false }
            return now.timeIntervalSince(last) <= graceSeconds
        }()

        let input = PowerInputs(
            restNow: restNow,
            pinnedUntil: pinnedUntil,
            reviewing: reviewing,
            agentHolds: result.agentHolds,
            processHolds: result.processHolds,
            workingCount: result.workingSessionCount,
            graceActive: graceActive,
            now: now
        )
        let decision = decidePower(input)
        controller.apply(decision)
        self.decision = decision
    }

    // MARK: - Derived UI state

    var iconSymbol: String {
        switch decision.iconState {
        case .working, .holding, .reviewing: return "cup.and.saucer.fill"
        case .idle, .suppressed: return "cup.and.saucer"
        }
    }

    var iconCount: Int? {
        (decision.iconState == .working && decision.workingCount > 0) ? decision.workingCount : nil
    }

    var headline: String {
        switch decision.iconState {
        case .idle: return "Everything is waiting on you. Mac sleeps normally."
        case .working: return decision.workingCount == 1
            ? "1 agent working. Mac stays awake."
            : "\(decision.workingCount) agents working. Mac stays awake."
        case .holding: return decision.reasons.first ?? "Holding this Mac awake."
        case .reviewing: return "Reviewing. Screen and Mac stay awake."
        case .suppressed: return "Resting. Rules are suppressed until you resume."
        }
    }

    var workingCount: Int { sessions.filter(\.isWorking).count }
    var waitingCount: Int { sessions.filter { !$0.isWorking }.count }
}
