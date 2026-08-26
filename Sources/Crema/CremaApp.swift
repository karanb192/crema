import SwiftUI
import AppKit

@main
struct CremaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Background-only agent: no Dock icon, no windows, just the menu bar item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let path = DemoMode.screenshotPath {
            Task { @MainActor in DemoMode.renderScreenshot(to: path) }
        }
    }
}

/// The menu bar glyph. Cup fills when a hold is active; the count is agents
/// mid-turn.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.iconSymbol)
            if let count = model.iconCount {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
