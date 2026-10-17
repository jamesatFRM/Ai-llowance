import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func reliabilityRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoreReliability-\(UUID().uuidString)")
    try Paths.prepare(root)
    return root
}
@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
        guard Date() < deadline else { throw UsageError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private actor NotificationDecision {
    var entered = false
    var finished = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
        entered = true
        let accepted = await withCheckedContinuation { continuation = $0 }
        finished = true
        return accepted
    }
    func accept() { continuation?.resume(returning: true); continuation = nil }
}

@Test @MainActor func malformedProviderSnapshotNeverReachesTheInterface() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, date in
        var window = try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 10)
        window.usedPercent = .nan
        return Snapshot(observedAt: date, windows: [window], identity: "fixture@example.com", source: "Broken provider")
    })
    let account = try store.add(name: "Test", kind: .codex, secret: "", existing: false)
    try await waitUntil { !store.refreshing }
    #expect(store.snapshots[account.id] == nil)
    #expect(store.accounts.first?.expectedIdentity == nil)
    #expect(store.errors[account.id] == UsageError.invalidData.localizedDescription)
    await store.shutdown()
}

@Test @MainActor func closedMenuExpiresAtQuotaResetWithoutAnotherProviderRead() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Paused", kind: .codex)
    let date = Date()
    let snapshot = Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 30,
        resetsAt: date.addingTimeInterval(20))], identity: "fixture@example.com", source: "Fixture", freshnessInterval: 1800)
    store.accounts = [account]; store.snapshots[account.id] = snapshot; store.paused = true
    #expect(store.heartbeatDelay(at: date) == 20)
    store.now = date.addingTimeInterval(21)
    #expect(store.menuEntries.first?.remainingPercent == nil)
    #expect(store.heartbeatDelay(at: store.now) == 900) // No repeated one-second wakeups after expiry.
    await store.shutdown()
}

@Test @MainActor func offlineMenuExpiresReadingAgeAndUTCMonthOnTime() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Offline", kind: .codex)
    let date = Date()
    store.accounts = [account]; store.offline = true
    store.snapshots[account.id] = Snapshot(observedAt: date.addingTimeInterval(-1790), identity: "fixture@example.com", source: "Fixture", freshnessInterval: 1800)
    #expect(store.heartbeatDelay(at: date) == 11)
    let costAccount = Account(name: "Monthly spending", kind: .openAIAPI)
    let monthEnd = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:59:45Z"))
    store.accounts = [costAccount]
    store.snapshots[costAccount.id] = Snapshot(observedAt: monthEnd, costUSD: 23, periodStart: CostAdapter.monthStart(monthEnd), source: "Fixture", freshnessInterval: 7200)
    #expect(store.heartbeatDelay(at: monthEnd) == 15)
    await store.shutdown()
}

@Test @MainActor func turningAlertsOffWhilePermissionIsPendingStaysOff() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let decision = NotificationDecision()
    let store = AppStore(root: root, monitor: false, requestNotificationAuthorization: { await decision.request() })
    store.setNotificationsEnabled(true)
    let deadline = Date().addingTimeInterval(5)
    while !(await decision.entered) {
        guard Date() < deadline else { throw UsageError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
    store.setNotificationsEnabled(false)
    await decision.accept()
    while !(await decision.finished) { try await Task.sleep(for: .milliseconds(10)) }
    // Let the MainActor consumer of the completed authorization resume.
    try await Task.sleep(for: .milliseconds(30))
    #expect(!store.notificationsEnabled)
    let restored = AppStore(root: root, monitor: false)
    #expect(!restored.notificationsEnabled)
    await restored.shutdown(); await store.shutdown()
}
