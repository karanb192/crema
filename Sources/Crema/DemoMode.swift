import AppKit
import SwiftUI
import CremaCore

/// Marketing screenshot mode. CREMA_DEMO=1 replaces the live scan with
/// realistic hypothetical sessions (never real folder names, see the repo
/// convention on demo assets); CREMA_SCREENSHOT=/path.png additionally renders
/// the popover to a 2x PNG and quits. Real UI code, synthetic data.
enum DemoMode {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["CREMA_DEMO"] == "1"
    }

    static var screenshotPath: String? {
        ProcessInfo.processInfo.environment["CREMA_SCREENSHOT"]
    }

    /// True while producing the marketing PNG. PopoverView swaps the AppKit
    /// switch for a SwiftUI lookalike then: ImageRenderer draws only pure
    /// SwiftUI, an NSViewRepresentable-backed control comes out as a
    /// placeholder.
    static var isScreenshotRun: Bool { enabled && screenshotPath != nil }

    static func sessions(now: Date = Date()) -> [AgentSession] {
        let home = NSHomeDirectory()
        func s(_ pid: Int32, _ rule: String, _ name: String,
               _ folder: String, _ working: Bool) -> AgentSession {
            AgentSession(pid: pid, ppid: 1, ruleID: rule, processName: name,
                         displayName: name, folder: home + folder, isWorking: working,
                         startedAt: now.addingTimeInterval(-3600),
                         lastActive: working ? now : now.addingTimeInterval(-300))
        }
        return [
            s(70101, "agent.claude", "Claude Code", "/dev/api-gateway", true),
            s(70102, "agent.claude", "Claude Code", "/prod/checkout-service", true),
            s(70103, "agent.claude", "Claude Code", "/dev/dashboard-ui", false),
            s(70104, "agent.claude", "Claude Code", "/prod/auth-service", false),
            s(70105, "agent.codex", "Codex CLI", "/dev/model-eval", true),
        ]
    }

    static func inputs(now: Date = Date()) -> PowerInputs {
        PowerInputs(agentHolds: ["Claude Code (2 working)", "Codex CLI (1 working)"],
                    workingCount: 3, now: now)
    }

    /// Renders the popover with the demo data, framed on the brand backdrop,
    /// to `path` at 2x, then quits.
    @MainActor
    static func renderScreenshot(to path: String) {
        let model = AppModel()
        let card = PopoverView()
            .environmentObject(model)
            .environment(\.colorScheme, .light)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 34, y: 18)
        let hero = card
            .padding(64)
            .background(
                RadialGradient(
                    colors: [Color(red: 0.33, green: 0.19, blue: 0.10),
                             Color(red: 0.090, green: 0.067, blue: 0.047)],
                    center: UnitPoint(x: 0.5, y: 0.32),
                    startRadius: 60, endRadius: 640)
            )
        let renderer = ImageRenderer(content: hero)
        renderer.scale = 2
        defer { NSApp.terminate(nil) }
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("Crema screenshot render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Pure-SwiftUI stand-in for the switch toggle, only for screenshot renders.
struct DemoSwitch: View {
    let on: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? tint : Color.secondary.opacity(0.35))
                .frame(width: 30, height: 18)
            Circle().fill(.white)
                .frame(width: 15, height: 15)
                .padding(1.5)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
    }
}
