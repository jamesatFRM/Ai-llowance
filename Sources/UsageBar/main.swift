import AppKit
import SwiftUI
import Combine
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var window: NSWindow?
    private var previewWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private let store = AppStore(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--preview"))
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "UsageBar")
            button.imagePosition = .imageLeading
            button.title = " Usage"
            button.target = self; button.action = #selector(togglePopover)
            button.toolTip = "Lowest remaining weekly quota across fresh, enabled accounts. Open for individual windows."
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Dashboard(store: store) { [weak self] in self?.showAccounts() })
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateLabel() }
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--preview") {
            let controller = NSHostingController(rootView: Dashboard(store: store) { [weak self] in self?.showAccounts() })
            let preview = NSWindow(contentViewController: controller)
            preview.title = "UsageBar · Sample preview"
            preview.styleMask = [.titled, .closable]
            preview.isReleasedWhenClosed = false
            preview.center(); preview.makeKeyAndOrderFront(nil)
            previewWindow = preview
            NSApp.activate(ignoringOtherApps: true)
        } else if store.accounts.isEmpty || store.demo || CommandLine.arguments.contains("--accounts") { showAccounts() }
        store.refresh()
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.async { [weak self] in self?.togglePopover() }
        }
    }
    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        let entries = store.menuEntries
        guard !entries.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "UsageBar")
            button.title = " Usage"
            button.toolTip = "UsageBar · Choose accounts in Settings"
            return
        }
        button.image = nil
        let title = NSMutableAttributedString(string: "")
        var descriptions: [String] = []
        for (index, entry) in entries.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ")) }
            if let image = ProviderImages.image(entry.provider) {
                image.size = NSSize(width: 13, height: 13)
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
                title.append(NSAttributedString(attachment: attachment))
            }
            let value = entry.remainingPercent.map { "\(Int($0))%" } ?? "—"
            let name = store.menuPreferences.display == .byAccount && store.menuPreferences.showAccountNames ? " \(String(entry.label.prefix(14)))" : ""
            title.append(NSAttributedString(string: "\(name) \(value)"))
            descriptions.append("\(entry.label): \(value) weekly remaining")
        }
        title.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
        button.toolTip = descriptions.joined(separator: "\n") + "\n\(store.menuPreferences.aggregation.title); each account has its own allowance."
        button.setAccessibilityLabel("UsageBar. " + descriptions.joined(separator: ". "))
    }
    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else if let button = statusItem.button {
            store.now = Date()
            store.refresh(force: true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            monitorOutsideClicks()
        }
    }
    private func closePopover() { popover.performClose(nil); removeClickMonitors() }
    private func monitorOutsideClicks() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closePopover(); return true }
                } else if event.window !== self.popover.contentViewController?.view.window,
                          event.window !== self.statusItem.button?.window {
                    self.closePopover()
                }
                return false
            }
            return consumed ? nil : event
        }
    }
    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }
    func popoverDidClose(_ notification: Notification) { removeClickMonitors() }
    func applicationDidResignActive(_ notification: Notification) { closePopover() }
    func applicationDidBecomeActive(_ notification: Notification) { store.refresh() }
    private func showAccounts() {
        store.now = Date()
        store.refresh(force: true)
        closePopover()
        if window == nil {
            let controller = NSHostingController(rootView: AccountsView(store: store) { [weak self] in
                self?.window?.orderOut(nil)
                self?.togglePopover()
            })
            let created = NSWindow(contentViewController: controller)
            created.title = "UsageBar · Settings"; created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 680, height: 750)); created.center()
            created.isReleasedWhenClosed = false; window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showAccounts(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
