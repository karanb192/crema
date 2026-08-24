import Foundation

/// Turns a `PowerDecision` into real IOKit assertions. Holds one system-sleep
/// assertion and one display-sleep assertion, flipping each on or off to match
/// the decision. Idempotent: applying the same decision twice is a no-op.
public final class AssertionController {
    private let systemAssertion = PowerAssertion(kind: .systemSleep)
    private let displayAssertion = PowerAssertion(kind: .displaySleep)

    public init() {}

    /// Applies the decision. Returns false if the OS refused a hold we wanted,
    /// so the caller can show a degraded state instead of a false promise.
    @discardableResult
    public func apply(_ decision: PowerDecision) -> Bool {
        var ok = true
        let reason = decision.reasons.first ?? "Keeping this Mac awake"

        if decision.systemHold {
            if !systemAssertion.isActive { ok = systemAssertion.start(reason: reason) && ok }
        } else {
            systemAssertion.stop()
        }

        if decision.displayHold {
            if !displayAssertion.isActive { ok = displayAssertion.start(reason: reason) && ok }
        } else {
            displayAssertion.stop()
        }

        return ok
    }

    public var holdsSystem: Bool { systemAssertion.isActive }
    public var holdsDisplay: Bool { displayAssertion.isActive }

    public func releaseAll() {
        systemAssertion.stop()
        displayAssertion.stop()
    }
}
