import Foundation

/// What the menu bar icon should show, mirroring the four states in the spec.
public enum IconState: String, Equatable {
    case idle        // holding nothing; Mac sleeps normally
    case working     // agents mid-turn; cup full + steam, count shown
    case holding     // a pin, timer, or batch rule holds; cup draining
    case reviewing   // display held too; cup full + display dot
    case suppressed  // Rest now; cup hollow with a slash
}

/// The inputs to the power decision, gathered each scan. Pure data so the
/// decision is deterministic and unit-testable.
public struct PowerInputs: Equatable {
    public var restNow: Bool
    public var pinnedUntil: Date?      // nil = no pin, .distantFuture = infinite
    public var reviewing: Bool
    public var agentHolds: [String]
    public var processHolds: [String]
    public var workingCount: Int
    public var now: Date

    public init(restNow: Bool = false,
                pinnedUntil: Date? = nil,
                reviewing: Bool = false,
                agentHolds: [String] = [],
                processHolds: [String] = [],
                workingCount: Int = 0,
                now: Date = Date()) {
        self.restNow = restNow
        self.pinnedUntil = pinnedUntil
        self.reviewing = reviewing
        self.agentHolds = agentHolds
        self.processHolds = processHolds
        self.workingCount = workingCount
        self.now = now
    }
}

/// The resolved decision the app applies to real assertions and the icon.
public struct PowerDecision: Equatable {
    public var systemHold: Bool
    public var displayHold: Bool
    public var iconState: IconState
    public var workingCount: Int
    public var reasons: [String]
}

/// The precedence ladder, as one pure function:
///   1. Rest now      -> suppress everything
///   2. Pin / Reviewing -> your intent, survives agents finishing
///   3. Agent + batch rules
///   4. Nothing active -> the Mac sleeps normally
public func decidePower(_ input: PowerInputs) -> PowerDecision {
    if input.restNow {
        return PowerDecision(systemHold: false, displayHold: false,
                             iconState: .suppressed, workingCount: 0,
                             reasons: ["Resting until you return"])
    }

    let pinActive = input.pinnedUntil.map { $0 > input.now } ?? false
    var reasons: [String] = []
    if pinActive { reasons.append(pinReason(until: input.pinnedUntil!, now: input.now)) }
    if input.reviewing { reasons.append("Reviewing, screen stays on") }
    reasons.append(contentsOf: input.agentHolds)
    reasons.append(contentsOf: input.processHolds)

    let ruleHold = !input.agentHolds.isEmpty || !input.processHolds.isEmpty
    let systemHold = pinActive || input.reviewing || ruleHold
    let displayHold = input.reviewing

    let iconState: IconState
    if !systemHold {
        iconState = .idle
    } else if input.reviewing {
        iconState = .reviewing
    } else if !input.agentHolds.isEmpty {
        iconState = .working
    } else if !input.processHolds.isEmpty {
        iconState = .working   // a batch tool is actively running
    } else {
        iconState = .holding   // a pin or timer with no live work
    }

    return PowerDecision(systemHold: systemHold, displayHold: displayHold,
                         iconState: iconState,
                         workingCount: input.workingCount,
                         reasons: reasons)
}

func pinReason(until: Date, now: Date) -> String {
    if until >= Date.distantFuture.addingTimeInterval(-1) { return "Pinned awake" }
    let minutes = max(1, Int(until.timeIntervalSince(now) / 60.0))
    return "Pinned for \(minutes) min"
}
