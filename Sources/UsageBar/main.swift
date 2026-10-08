import AppKit
import SwiftUI
import Combine
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var window: NSWindow?
    private var previewWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
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
    }
    private func updateLabel() { statusItem?.button?.title = " " + store.menuLabel }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            store.now = Date()
            store.refresh(force: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    private func showAccounts() {
        store.now = Date()
        store.refresh(force: true)
        popover.performClose(nil)
        if window == nil {
            let controller = NSHostingController(rootView: AccountsView(store: store))
            let created = NSWindow(contentViewController: controller)
            created.title = "UsageBar · Accounts"; created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 660, height: 770)); created.center()
            created.isReleasedWhenClosed = false; window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
