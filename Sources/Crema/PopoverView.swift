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
            Divider()

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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottomLeading) {
            Text(model.headline)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, -6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var restBanner: some View {
        HStack {
            Text("Resting. Everything is suppressed until you resume.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") { model.resume() }
                .buttonStyle(.borderedProminent)
                .tint(crema)
        }
        .padding(14)
    }

    private var rulesAndSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rules) { rule in
                ruleRow(rule)
                ForEach(model.sessions.filter { $0.ruleID == rule.id }) { session in
                    sessionRow(session)
                }
            }
        }
        .padding(.vertical, 4)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Right now")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                chip("Reviewing", active: model.reviewing) { model.toggleReviewing() }
                chip("30 min", active: isPinned(minutes: 30)) { model.pin(minutes: 30) }
                chip("Forever", active: isInfinitePin()) { model.pin(minutes: nil) }
                chip("Rest now", active: false) { model.rest() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
        guard let until = model.pinnedUntil, until < .distantFuture else { return false }
        return true
    }

    private func isInfinitePin() -> Bool {
        model.pinnedUntil == .distantFuture
    }
}
