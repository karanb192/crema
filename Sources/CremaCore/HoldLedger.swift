import Foundation

/// Rolling record of when Crema held the Mac awake, so the popover can show
/// an honest, falsifiable ledger line ("Awake 2.9 h of the last 10 h,
/// released 14 times"). Events collapse consecutive states and are pruned to
/// the trailing window, so the array stays tiny.
public struct HoldLedger: Codable, Equatable {
    public struct Event: Codable, Equatable {
        public var held: Bool
        public var at: Date

        public init(held: Bool, at: Date) {
            self.held = held
            self.at = at
        }
    }

    public private(set) var events: [Event] = []
    public var window: TimeInterval = 24 * 3600

    public init() {}

    /// Record the current hold state. Consecutive identical states collapse
    /// into the first occurrence.
    public mutating func record(held: Bool, at: Date = Date()) {
        if events.last?.held == held { return }
        events.append(Event(held: held, at: at))
        prune(now: at)
    }

    /// Drop events older than the window, clamping the earliest survivor to
    /// the window edge so held time never counts beyond it.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        while events.count > 1, events[1].at <= cutoff {
            events.removeFirst()
        }
        if let first = events.first, first.at < cutoff {
            events[0] = Event(held: first.held, at: cutoff)
        }
    }

    public struct Summary: Equatable {
        public var heldSeconds: TimeInterval
        public var spanSeconds: TimeInterval
        public var releaseCount: Int

        public init(heldSeconds: TimeInterval, spanSeconds: TimeInterval, releaseCount: Int) {
            self.heldSeconds = heldSeconds
            self.spanSeconds = spanSeconds
            self.releaseCount = releaseCount
        }
    }

    public func summary(now: Date = Date()) -> Summary {
        guard let first = events.first else {
            return Summary(heldSeconds: 0, spanSeconds: 0, releaseCount: 0)
        }
        var held: TimeInterval = 0
        var releases = 0
        for (index, event) in events.enumerated() {
            let end = index + 1 < events.count ? events[index + 1].at : now
            if event.held { held += max(0, end.timeIntervalSince(event.at)) }
            if !event.held && index > 0 { releases += 1 }
        }
        return Summary(heldSeconds: held,
                       spanSeconds: max(0, now.timeIntervalSince(first.at)),
                       releaseCount: releases)
    }
}
