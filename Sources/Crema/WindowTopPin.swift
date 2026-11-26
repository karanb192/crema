import SwiftUI
import AppKit

/// Keeps the popover hanging from the menu bar when its content changes
/// height. AppKit resizes a window around its bottom-left corner, so when the
/// popover's content gets shorter while it is open (the scan on open drops a
/// session that ended, or one ends mid-view), the window's top slides down and
/// leaves a gap under the menu bar. This moves the window back so its top edge
/// stays where the system placed it.
struct WindowTopPin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PinView: NSView {
        private var top: CGFloat?
        private var observers: [NSObjectProtocol] = []

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            top = window.frame.maxY
            let center = NotificationCenter.default
            // The system positions the window under the menu bar on each open;
            // that is a move, so it sets the top to hold.
            observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                self?.top = self?.window?.frame.maxY
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.keepTop()
            })
        }

        private func keepTop() {
            guard let window, window.isVisible, let top else { return }
            let frame = window.frame
            guard abs(frame.maxY - top) > 0.5 else { return }
            window.setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
        }
    }
}
