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

    private var rulesAndSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rules) { rule in
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
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { model.setRule(id: rule.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(crema)
            .scaleEffect(0.8)

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

    /// Manual holds. Every chip is a toggle: click to hold, click again to
    /// stop. Active finite pins show the time remaining in place of the
    /// duration so the label doubles as the countdown.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Keep awake")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                chip("Screen on", active: model.reviewing) { model.toggleReviewing() }
                    .help("Keep the Mac awake and the screen from dimming, until you turn it off")
                chip(pinChipTitle(minutes: 30, idle: "30 min"), active: isPinned(minutes: 30)) {
                    isPinned(minutes: 30) ? model.clearPin() : model.pin(minutes: 30)
                }
                .help("Keep the Mac awake for 30 minutes, whatever agents do")
                chip(pinChipTitle(minutes: 60, idle: "1 hr"), active: isPinned(minutes: 60)) {
                    isPinned(minutes: 60) ? model.clearPin() : model.pin(minutes: 60)
                }
                .help("Keep the Mac awake for 1 hour, whatever agents do")
                chip("Until off", active: isInfinitePin()) {
                    isInfinitePin() ? model.clearPin() : model.pin(minutes: nil)
                }
                .help("Keep the Mac awake until you turn it off")
            }
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

    /// "30 min" when idle, "22 min" (remaining) while that pin is running.
    private func pinChipTitle(minutes: Int, idle: String) -> String {
        guard isPinned(minutes: minutes), let until = model.pinnedUntil else { return idle }
        let remaining = max(1, Int((until.timeIntervalSinceNow + 59) / 60.0))
        return "\(remaining) min"
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
            return "holds while it runs"
        }
    }

    private func isPinned(minutes: Int) -> Bool {
        model.pinnedMinutes == minutes
    }

    private func isInfinitePin() -> Bool {
        model.pinnedUntil == .distantFuture
    }
}
