import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func dashboardRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DashboardChoices-\(UUID().uuidString)")
    try Paths.prepare(root); return root
}
@MainActor private func finishPermission(_ store: AppStore) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.notificationPending { guard Date() < deadline else { throw UsageError.timeout }; try await Task.sleep(for: .milliseconds(10)) }
}
private actor PermissionProbe {
    var states: [NotificationAccess]
    var requests = 0
    var tests = 0
    var failRequest = false
    init(_ states: [NotificationAccess], fail: Bool = false) { self.states = states; failRequest = fail }
    func read() -> NotificationAccess { if states.count > 1 { return states.removeFirst() }; return states.first ?? .unknown }
    func request() throws -> Bool { requests += 1; if failRequest { throw UsageError.unavailable("Fixture permission service error") }; return true }
    func test() { tests += 1 }
    nonisolated var client: NotificationPermissionClient {
        .init(read: { await self.read() }, request: { try await self.request() }, test: { await self.test() })
    }
}
private actor DelayedPermissionError {
    var continuation: CheckedContinuation<Bool, any Error>?
    var entered = false
    func request() async throws -> Bool { entered = true; return try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish() { continuation?.resume(throwing: UsageError.timeout); continuation = nil }
}

@Test @MainActor func alreadyAllowedNotificationsDoNotAskAgainOrLeaveAStaleError() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = PermissionProbe([.init(authorization: .allowed)])
    let store = AppStore(root: root, monitor: false, notificationClient: probe.client)
    store.notice = "Could not enable notifications. Check System Settings → Notifications."
    store.setNotificationsEnabled(true); try await finishPermission(store)
    #expect(store.notificationsEnabled && store.notice == nil && store.notificationMessage == nil)
    #expect(await probe.requests == 0)
    store.sendTestNotification()
    let deadline = Date().addingTimeInterval(5)
    while store.notificationMessage == nil { guard Date() < deadline else { throw UsageError.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await probe.tests == 1)
    await store.shutdown()
}

@Test @MainActor func blockedPermissionShowsSettingsRecoveryAndReturningEnablesTheRequestedAlerts() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = PermissionProbe([.init(authorization: .denied), .init(authorization: .allowed)])
    var opened: URL?
    let store = AppStore(root: root, monitor: false, notificationClient: probe.client, openExternal: { opened = $0; return true })
    store.setNotificationsEnabled(true); try await finishPermission(store)
    #expect(!store.notificationsEnabled && store.notificationAccess.authorization == .denied)
    #expect(await probe.requests == 0)
    #expect(store.notice == nil)
    store.openNotificationSettings()
    #expect(opened?.scheme == "x-apple.systempreferences")
    store.refreshNotificationAccess()
    let deadline = Date().addingTimeInterval(5)
    while !store.notificationsEnabled { guard Date() < deadline else { throw UsageError.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.notificationAccess.canDeliver)
    await store.shutdown()
    let restored = AppStore(root: root, monitor: false)
    #expect(restored.notificationsEnabled)
    await restored.shutdown()
}

@Test @MainActor func anInterruptedPermissionReplyRechecksTheActualGrantedStatus() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = PermissionProbe([.init(authorization: .notDetermined), .init(authorization: .allowed)], fail: true)
    let store = AppStore(root: root, monitor: false, notificationClient: probe.client)
    store.setNotificationsEnabled(true); try await finishPermission(store)
    #expect(store.notificationsEnabled && store.notificationMessage == nil)
    #expect(await probe.requests == 1)
    await store.shutdown()
}

@Test @MainActor func aPermissionServiceFailureHasAnActionableRetryWithoutClaimingSuccess() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = PermissionProbe([.init(authorization: .notDetermined)], fail: true)
    let store = AppStore(root: root, monitor: false, notificationClient: probe.client)
    store.setNotificationsEnabled(true); try await finishPermission(store)
    #expect(!store.notificationsEnabled)
    #expect(store.notificationMessage?.contains("Try again") == true)
    #expect(!store.notificationPending)
    await store.shutdown()
}

@Test @MainActor func turningNotificationsOffDiscardsALatePermissionFailure() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = DelayedPermissionError()
    let client = NotificationPermissionClient(read: { .init(authorization: .notDetermined) }, request: { try await gate.request() }, test: {})
    let store = AppStore(root: root, monitor: false, notificationClient: client)
    store.setNotificationsEnabled(true)
    let deadline = Date().addingTimeInterval(5)
    while !(await gate.entered) { guard Date() < deadline else { throw UsageError.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    store.setNotificationsEnabled(false)
    await gate.finish()
    try await Task.sleep(for: .milliseconds(30))
    #expect(!store.notificationsEnabled && !store.notificationPending && store.notificationMessage == nil)
    await store.shutdown()
}

@Test @MainActor func accountChartComparisonAndCollapseChoicesSurviveRestartIndependently() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let first = Account(name: "First", kind: .claudeCode), second = Account(name: "Second", kind: .codex)
    let store = AppStore(root: root, monitor: false)
    store.accounts = [first, second]
    store.setAccountChart(first.id, style: .glow)
    store.setAccountComparison(first.id, period: .week)
    store.setAccountCollapsed(second.id, collapsed: true)
    store.setDashboardSummaryCollapsed("activity", collapsed: true)
    await store.shutdown()
    let restored = AppStore(root: root, monitor: false)
    #expect(restored.accounts[0].dashboardChartStyle == .glow && restored.accounts[0].dashboardComparison == .week)
    #expect(restored.accounts[1].dashboardChartStyle == nil && restored.accounts[1].dashboardComparison == nil)
    #expect(restored.accounts[1].dashboardCollapsed == true)
    #expect(restored.menuPreferences.collapsedDashboardSummaries == ["activity"])
    restored.setAllDashboardCollapsed(true)
    #expect(restored.dashboardAllCollapsed)
    restored.setAllDashboardCollapsed(false)
    #expect(restored.accounts.allSatisfy { $0.dashboardCollapsed == false })
    #expect(restored.accounts[0].dashboardChartStyle == .glow && restored.accounts[0].dashboardComparison == .week)
    #expect(restored.menuPreferences.collapsedDashboardSummaries.isEmpty)
    await restored.shutdown()
}

@Test @MainActor func failedDashboardSaveRestoresTheOriginalLayoutAndAccountPreferences() async throws {
    let root = try dashboardRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let account = Account(name: "Fixture", kind: .codex)
    let store = AppStore(root: root, monitor: false)
    store.accounts = [account]
    try FileManager.default.createDirectory(at: root.appendingPathComponent("accounts.json"), withIntermediateDirectories: false)
    store.setAccountChart(account.id, style: .area)
    #expect(store.accounts == [account])
    store.setAllDashboardCollapsed(true)
    #expect(store.accounts == [account] && store.menuPreferences.collapsedDashboardSummaries.isEmpty)
    await store.shutdown()
}
