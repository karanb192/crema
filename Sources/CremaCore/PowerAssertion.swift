import Foundation
import IOKit.pwr_mgt

/// A single IOKit power assertion, the same mechanism `caffeinate` uses.
///
/// `IOPMAssertionCreateWithName` tells macOS to hold off a specific kind of
/// idle sleep until the assertion is released. We wrap one assertion per
/// instance so the coordinator can turn each reason on and off independently.
public final class PowerAssertion {
    public enum Kind {
        /// Keep the whole system awake (the machine does not idle-sleep).
        case systemSleep
        /// Keep the display on (used only while the user is reviewing).
        case displaySleep

        var typeName: String {
            switch self {
            case .systemSleep: return kIOPMAssertionTypePreventUserIdleSystemSleep
            case .displaySleep: return kIOPMAssertionTypePreventUserIdleDisplaySleep
            }
        }
    }

    public let kind: Kind
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) public var isActive = false

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Create the assertion with a human-readable reason. Returns false if the
    /// OS refused, in which case nothing is held and the caller should surface it.
    @discardableResult
    public func start(reason: String) -> Bool {
        guard !isActive else { return true }
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.typeName as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = newID
        isActive = true
        return true
    }

    public func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    deinit { stop() }
}
