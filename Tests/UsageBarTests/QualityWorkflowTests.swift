import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test @MainActor func upgradeRestoresYearOfHistoryAndPreferencesWithoutProviderReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityUpgrade-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.prepare(root)
    var first = Account(name: "Personal", kind: .claudeCode); first.expectedIdentity = "personal@example.com"
    var second = Account(name: "Work", kind: .codex); second.expectedIdentity = "work@example.com"
    var prefs = MenuPreferences()
    prefs.dashboardAccountOrder = [second.id, first.id]; prefs.accountOrder = [first.id, second.id]
    prefs.theme = .light; prefs.dashboardTransparency = 0.4; prefs.dropdownTransparency = 0.8
    prefs.resetRemindersEnabled = true; prefs.secondResetReminderEnabled = true
    prefs.secondResetReminderMinimumPercent = 76; prefs.resetReminderLeadHours = 48
    struct Saved: Encodable { let accounts: [Account]; let paused: Bool; let menuPreferences: MenuPreferences; let notificationsEnabled: Bool }
    try Paths.write(Saved(accounts: [first, second], paused: true, menuPreferences: prefs, notificationsEnabled: true), to: root.appendingPathComponent("accounts.json"))
    let now = Date(), old = HistoryTrends.calendar.startOfDay(for: Date()).addingTimeInterval(-365 * 86400 + 3600)
    let cache = SnapshotCache(root: root)
    for account in [first, second] {
        let id = account.kind == .codex ? "codex.week" : "week.all models"
        var reading = Snapshot(observedAt: old, windows: [try QuotaWindow(id: id, label: "Week", usedPercent: 10, durationMinutes: 10080)], identity: account.expectedIdentity, source: "Fixture")
        try cache.save(reading, for: account)
        reading.observedAt = old.addingTimeInterval(300); reading.windows[0].usedPercent = 15
        try cache.save(reading, for: account)
        reading.observedAt = now; try cache.save(reading, for: account)
    }
    let originalSettings = try Data(contentsOf: root.appendingPathComponent("accounts.json"))
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in Issue.record("Upgrade must not invoke a provider"); throw UsageError.server })
    #expect(store.accounts == [first, second])
    #expect(store.menuPreferences == prefs)
    #expect(store.orderedDashboardAccounts.map(\.id) == [second.id, first.id])
    #expect(store.orderedMenuAccounts.map(\.id) == [first.id, second.id])
    #expect(store.usageDays[first.id]?.first?.weekly?.amount == 5)
    #expect(store.usageDays[second.id]?.first?.weekly?.amount == 5)
    #expect(store.history(for: first).first!.timestamp < now.addingTimeInterval(-364 * 86400))
    #expect(store.connectionState(first).saved)
    store.setDashboardVisible(true); store.setDashboardVisible(false)
    #expect(!store.dashboardVisible && !store.refreshing)
    #expect(try Data(contentsOf: root.appendingPathComponent("accounts.json")) == originalSettings)
    await store.shutdown()
}

@Test @MainActor func accountRecoveryUsesItsOwnRefreshStateAndProviderDeadline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityRecovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.rateLimited(3600) })
    let account = Account(name: "Fixture", kind: .codex, usesExistingCodex: true)
    store.accounts = [account]
    store.refresh()
    let deadline = Date().addingTimeInterval(5)
    while store.refreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.recoveryAction(account) == .wait)
    store.retryConnection(account)
    #expect(!store.refreshing)
    store.signingIn = account.id
    #expect(store.recoveryAction(account) == .finishSignIn)
    await store.shutdown()
}

@Test @MainActor func requestingSettingsAndHidingChartsDoNotStartProviderWork() async {
    let store = AppStore(demo: true)
    let accounts = store.accounts, snapshots = store.snapshots
    store.setDashboardVisible(false)
    #expect(!store.dashboardVisible)
    store.requestSettings(); store.requestSettings()
    #expect(store.settingsNavigationVersion == 2)
    store.setDashboardVisible(true)
    #expect(store.accounts == accounts && store.snapshots == snapshots)
    #expect(!store.refreshing)
    let report = try? await store.diagnosticReport()
    #expect(report?.contains("alex@example.com") == false)
    #expect(report?.contains("work@example.com") == false)
    await store.shutdown()
}

@Test @MainActor func sampleAppearanceControlsOnlyChangeFictionalAccounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityDemo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(demo: true, root: root)
    let account = try #require(store.accounts.first)
    #expect(store.setAccountAppearance(account, name: "Sample name", menu: "123456", dashboard: "654321", graph: "ABCDEF"))
    store.setTheme(.light); store.setDropdownTransparency(0.5)
    #expect(store.accounts.first?.name == "Sample name")
    #expect(store.menuPreferences.theme == .light)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    await store.shutdown()
}
