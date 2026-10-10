import AppKit
import SwiftUI
import Carbon

@main
enum BitClipboardMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: ClipboardStore!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ClipboardStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "BitClipboard 剪贴板历史")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "BitClipboard · 剪贴板历史（⌃⌥V）"
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 610)
        popover.contentViewController = NSHostingController(rootView: ClipboardView(store: store))
        registerShortcut()
        if CommandLine.arguments.contains("--show") { togglePopover() }
    }

    func popoverWillShow(_ notification: Notification) {
        stopDismissalMonitoring()
        // Mouse monitoring needs no Accessibility permission and never consumes
        // the click, so the user's destination app still receives it normally.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissalMonitoring()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }

    private func stopDismissalMonitoring() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            store.poll()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.togglePopover()
            return noErr
        }, 1, &type, pointer, &eventHandler)
        let id = EventHotKeyID(signature: 0x42434C50, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { store.error = "⌃⌥V 快捷键已被占用，请通过菜单栏图标打开。" }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDismissalMonitoring()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
