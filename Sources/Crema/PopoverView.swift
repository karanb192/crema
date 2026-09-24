import SwiftUI
import CremaCore

/// The popover shown when the menu bar cup is clicked. Header verdict, the
/// rules and the sessions they cover, then the "right now" intent chips.
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel

    private let crema = Color(red: 0.706, green: 0.388, blue: 0.184) // #B4632F

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.restNow {
                restBanner
            } else {
                rulesAndSessions
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.decision.systemHold ? crema : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text("Crema")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Text(model.decision.systemHold ? "awake" : "sleeps")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(model.headline)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let line = model.ledgerLine {
                Text(line)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var restBanner: some View {
        HStack {
            Text("Paused. Crema isn't keeping the Mac awake.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") { model.resume() }
                .buttonStyle(.borderedProminent)
                .tint(crema)
        }
        .padding(14)
    }

    /// Cap visible sessions per rule so 20 or 30 agents stay usable. Sessions
    /// are already sorted working-first, so the shown ones are the ones you act
    /// on; the rest collapse into a "+ N more" row. Rendered as a plain stack:
    /// a ScrollView here collapses to zero height inside a menu bar popover,
    /// and the per-rule cap already bounds the height.
    private let maxSessionsShown = 5

    /// Agent rules are standing workflows and always show. Batch rules
    /// (ffmpeg and friends) are transient: their row appears only while the
    /// process actually exists, so the default list never carries dead rows
    /// for tools you are not running.
    private var visibleRules: [Rule] {
        model.rules.filter { rule in
            switch rule.kind {
            case .whileAgentWorking: return true
            case .whileProcessRuns: return model.runningBatchRuleIDs.contains(rule.id)
            }
        }
    }

    private var rulesAndSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleRules) { rule in
                ruleRow(rule)
                let ruleSessions = model.sessions.filter { $0.ruleID == rule.id }
                ForEach(ruleSessions.prefix(maxSessionsShown)) { session in
                    sessionRow(session)
                }
                if ruleSessions.count > maxSessionsShown {
                    moreRow(hidden: ruleSessions.count - maxSessionsShown,
                            hiddenWorking: ruleSessions.dropFirst(maxSessionsShown).filter(\.isWorking).count)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func moreRow(hidden: Int, hiddenWorking: Int) -> some View {
        HStack {
            Text(hiddenWorking > 0
                 ? "+ \(hidden) more (\(hiddenWorking) working)"
                 : "+ \(hidden) more")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
    }

    private func ruleRow(_ rule: Rule) -> some View {
        HStack(spacing: 8) {
            if DemoMode.isScreenshotRun {
                DemoSwitch(on: rule.enabled, tint: crema)
            } else {
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.setRule(id: rule.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(crema)
                .scaleEffect(0.8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(ruleSubtitle(rule))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isWorking ? crema : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.shortFolder.isEmpty ? "pid \(session.pid)" : session.shortFolder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(session.isWorking ? "working" : "waiting for you")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
        .opacity(session.isWorking ? 1 : 0.65)
    }

    /// Manual holds, two axes. The chip row is the duration: quick presets
    /// plus a menu carrying the longer holds and "Until I turn it off". The
    /// checkbox beneath is the screen modifier. Every chip is a toggle: click
    /// to hold, click again to stop; active pins count down in place.
    private let quickPins = [30, 60, 120]
    private static let menuPins = [180, 240, 360, 480]

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Keep awake")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(quickPins, id: \.self) { minutes in
                    chip(pinChipTitle(minutes: minutes), active: isPinned(minutes: minutes)) {
                        isPinned(minutes: minutes) ? model.clearPin() : model.pin(minutes: minutes)
                    }
                    .help("Keep the Mac awake for \(Self.durationHelp(minutes)), whatever agents do")
                }
                moreChip
            }
            screenOnRow
            HStack {
                Button("Pause Crema") { model.rest() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Stop keeping the Mac awake until you resume. It sleeps on its normal schedule.")
                Spacer()
                Button("Quit Crema") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The longer durations and the infinite hold live in a menu, so the chip
    /// row stays four wide and "Until I turn it off" never again sits next to
    /// the screen control looking like its twin. While one of its durations
    /// runs, this chip is the countdown and the menu leads with "Turn off".
    private var moreChip: some View {
        Group {
            if DemoMode.isScreenshotRun {
                chip(moreChipTitle, active: menuPinActive) {}
            } else {
                Menu {
                    if menuPinActive {
                        Button("Turn off") { model.clearPin() }
                        Divider()
                    }
                    ForEach(Self.menuPins, id: \.self) { minutes in
                        Button("\(minutes / 60) hours") { model.pin(minutes: minutes) }
                    }
                    Divider()
                    Button("Until I turn it off") { model.pin(minutes: nil) }
                } label: {
                    Text(moreChipTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .background(menuPinActive ? crema.opacity(0.16) : Color.secondary.opacity(0.1))
                .foregroundStyle(menuPinActive ? crema : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .help("Longer holds: 3 to 8 hours, or until you turn it off")
            }
        }
    }

    private var screenOnRow: some View {
        HStack(spacing: 7) {
            if DemoMode.isScreenshotRun {
                DemoCheckbox(on: model.keepScreenOn, tint: crema)
                Text("Keep the screen on too")
                    .font(.system(size: 11.5))
            } else {
                Toggle(isOn: Binding(
                    get: { model.keepScreenOn },
                    set: { model.setScreenOn($0) }
                )) {
                    Text("Keep the screen on too")
                        .font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox)
            }
            Spacer()
        }
        .help("The screen stays lit while anything holds the Mac awake. Without this, the screen can dim and lock while the Mac works underneath.")
    }

    private var menuPinActive: Bool {
        if isInfinitePin() { return true }
        if let minutes = model.pinnedMinutes { return Self.menuPins.contains(minutes) }
        return false
    }

    private var moreChipTitle: String {
        if isInfinitePin() { return "Until off" }
        if let minutes = model.pinnedMinutes, Self.menuPins.contains(minutes),
           let until = model.pinnedUntil {
            return Self.remainingLabel(until: until)
        }
        return "More ▾"
    }

    /// "30 min" / "1 hr" / "2 hr" when idle; the remaining time while running.
    private func pinChipTitle(minutes: Int) -> String {
        guard isPinned(minutes: minutes), let until = model.pinnedUntil else {
            return Self.durationLabel(minutes)
        }
        return Self.remainingLabel(until: until)
    }

    private static func durationLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }

    private static func durationHelp(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    private static func remainingLabel(until: Date) -> String {
        let remaining = max(1, Int((until.timeIntervalSinceNow + 59) / 60.0))
        if remaining < 60 { return "\(remaining) min" }
        let hours = remaining / 60, minutes = remaining % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) m"
    }

    // MARK: - Bits

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(active ? crema.opacity(0.16) : Color.secondary.opacity(0.1))
        .foregroundStyle(active ? crema : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func ruleSubtitle(_ rule: Rule) -> String {
        switch rule.kind {
        case .whileAgentWorking:
            let n = model.sessions.filter { $0.ruleID == rule.id }.count
            return n == 0 ? "no sessions running" : "\(n) session\(n == 1 ? "" : "s") · holds while working"
        case .whileProcessRuns:
            return rule.enabled ? "running · holds until it exits" : "running · not holding"
        }
    }

    private func isPinned(minutes: Int) -> Bool {
        model.pinnedMinutes == minutes
    }

    private func isInfinitePin() -> Bool {
        model.pinnedUntil == .distantFuture
    }
}
