import AppKit
import SwiftUI
import Combine
import UsageCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var window: NSWindow?
    private var previewWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var popoverResizeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var notificationDelegate: AllowanceNotificationDelegate?
    private var renderedEntries: [MenuEntry]?
    private var renderedPreferences: MenuPreferences?
    private let store = AppStore(demo: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--export-preview"))
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--export-preview"), CommandLine.arguments.count > index + 1 {
            do { try SharePreview.export(store: store, directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("Could not render the sample preview.\n", stderr); exit(1) }
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Brand.menuMark()
            button.imagePosition = .imageLeading
            button.title = " Usage"
            button.target = self; button.action = #selector(togglePopover)
            button.toolTip = "Remaining allowance for your selected accounts. Open for limits and resets."
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Dashboard(store: store) { [weak self] in self?.showAccounts() })
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateLabel() }
        }.store(in: &subscriptions)
        store.$menuPreferences.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyWindowAppearance() }
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--preview") {
            let controller = NSHostingController(rootView: Dashboard(store: store) { [weak self] in self?.showAccounts() })
            let preview = NSWindow(contentViewController: controller)
            preview.title = "Ai-llowance · Sample preview"
            preview.styleMask = [.titled, .closable]
            preview.isReleasedWhenClosed = false
            preview.center(); preview.makeKeyAndOrderFront(nil)
            previewWindow = preview
            NSApp.activate(ignoringOtherApps: true)
        } else if store.accounts.isEmpty || store.demo || CommandLine.arguments.contains("--accounts") { showAccounts() }
        if !store.demo {
            let notifications = AllowanceNotificationDelegate { [weak self] id in
                self?.store.selectedAccountID = id
                self?.showAccounts()
            }
            notificationDelegate = notifications
            UNUserNotificationCenter.current().delegate = notifications
        }
        store.updater.start()
        updateLabel()
        store.refresh()
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.async { [weak self] in self?.togglePopover() }
        }
    }
    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        let entries = store.menuEntries
        guard renderedEntries != entries || renderedPreferences != store.menuPreferences else { return }
        renderedEntries = entries; renderedPreferences = store.menuPreferences
        guard !entries.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Brand.menuMark()
            button.title = " Usage"
            button.toolTip = "Ai-llowance · Choose accounts in Settings"
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
            let value = menuValue(entry)
            let name = store.menuPreferences.showAccountNames && (store.menuPreferences.display == .byAccount || entry.isBalance) ? " \(String(entry.label.prefix(12)))" : ""
            title.append(NSAttributedString(string: "\(name) \(value)"))
            descriptions.append(entry.isBalance ? "\(entry.label): \(entry.balanceUSD?.formatted(.currency(code: "USD")) ?? "balance unavailable")"
                : entry.isUnlimited ? "\(entry.label): unlimited allowance" : entry.remainingPercent == nil
                ? "\(entry.label): allowance unavailable"
                : "\(entry.label): \(value) allowance remaining")
        }
        title.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
        button.toolTip = descriptions.joined(separator: "\n") + "\n\(store.menuPreferences.aggregation.title); each account has its own allowance."
        button.setAccessibilityLabel("Ai-llowance. " + descriptions.joined(separator: ". "))
    }
    private func menuValue(_ entry: MenuEntry) -> String {
        if entry.isBalance { return entry.balanceUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) ?? "—" }
        return entry.isUnlimited ? "∞" : (entry.remainingPercent.map { "\(Int($0))%" } ?? "—")
    }
    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else if let button = statusItem.button {
            store.setInterfaceVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            if let controller = popover.contentViewController as? NSHostingController<Dashboard> {
                controller.rootView = Dashboard(store: store, maximumHeight: (button.window?.screen?.visibleFrame.height ?? 700) - 24) { [weak self] in self?.showAccounts() }
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            applyWindowAppearance()
            popover.contentViewController?.view.window?.makeKey()
            constrainPopoverToScreen()
            monitorOutsideClicks()
        }
    }
    func popoverDidShow(_ notification: Notification) {
        constrainPopoverToScreen()
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: popoverWindow, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.constrainPopoverToScreen() }
            }
        }
    }
    private func constrainPopoverToScreen() {
        guard popover.isShown, let panel = popover.contentViewController?.view.window,
              let screen = statusItem.button?.window?.screen ?? panel.screen else { return }
        let available = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        let origin = PopoverPlacement.origin(for: panel.frame, inside: available)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
    private func closePopover() { popover.performClose(nil); removeClickMonitors(); store.setInterfaceVisible(hasVisibleSettings) }
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
    func popoverDidClose(_ notification: Notification) {
        if let popoverResizeObserver { NotificationCenter.default.removeObserver(popoverResizeObserver); self.popoverResizeObserver = nil }
        removeClickMonitors(); store.setInterfaceVisible(hasVisibleSettings) }
    private var hasVisibleSettings: Bool {
        window?.isVisible == true && window?.isMiniaturized != true && !NSApp.isHidden
    }
    func applicationDidHide(_ notification: Notification) { closePopover() }
    func applicationDidUnhide(_ notification: Notification) { store.setInterfaceVisible(popover.isShown || hasVisibleSettings) }
    func windowDidMiniaturize(_ notification: Notification) { store.setInterfaceVisible(popover.isShown || hasVisibleSettings) }
    func windowDidDeminiaturize(_ notification: Notification) { store.setInterfaceVisible(popover.isShown || hasVisibleSettings) }
    func applicationDidResignActive(_ notification: Notification) { closePopover() }
    func applicationDidBecomeActive(_ notification: Notification) { store.rediscoverTools(); store.refresh() }
    func windowWillClose(_ notification: Notification) { store.setInterfaceVisible(popover.isShown) }
    private func showAccounts() {
        closePopover()
        store.setInterfaceVisible(true)
        if window == nil {
            let controller = NSHostingController(rootView: AccountsView(store: store) { [weak self] in
                self?.window?.orderOut(nil)
                self?.togglePopover()
            })
            let created = NSWindow(contentViewController: controller)
            created.title = "Ai-llowance · Dashboard"; created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 1060, height: 800)); created.center()
            created.isReleasedWhenClosed = false; created.delegate = self; window = created
        }
        applyWindowAppearance()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func applyWindowAppearance() {
        let appearance: NSAppearance?
        switch store.menuPreferences.theme {
        case .automatic: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        window?.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showAccounts(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        removeClickMonitors()
        Task { await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
