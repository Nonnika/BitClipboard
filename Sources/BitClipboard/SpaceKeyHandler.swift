import AppKit
import SwiftUI

/// A window-scoped shortcut that leaves text entry and other windows alone.
struct SpaceKeyHandler: NSViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> SpaceKeyMonitorView {
        SpaceKeyMonitorView(frame: .zero)
    }

    func updateNSView(_ view: SpaceKeyMonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }

    static func dismantleNSView(_ view: SpaceKeyMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SpaceKeyMonitorView: NSView {
    var isEnabled = false
    var action: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isEnabled, let window = self.window,
                  window.isVisible, NSApp.isActive, event.window === window,
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
            if window.firstResponder is NSTextField { return event }
            // Holding space must not repeatedly open and close the preview.
            if !event.isARepeat { self.action() }
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit { stopMonitoring() }
}
