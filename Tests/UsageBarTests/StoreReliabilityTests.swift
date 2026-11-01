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

@Test @MainActor func closedMenuMarksLastKnownAtQuotaResetWithoutAnotherProviderRead() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Paused", kind: .codex)
    let date = Date()
    let snapshot = Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 30,
        resetsAt: date.addingTimeInterval(20))], identity: "fixture@example.com", source: "Fixture", freshnessInterval: 1800)
    store.accounts = [account]; store.snapshots[account.id] = snapshot; store.paused = true
    #expect(store.heartbeatDelay(at: date) == 20)
    store.now = date.addingTimeInterval(21)
    #expect(store.menuEntries.first?.remainingPercent == 70)
    #expect(store.menuEntries.first?.isLastKnown == true)
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

@Test @MainActor func failedRefreshKeepsReadingAndHistoryAndRecoveryClearsMarker() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.timeout })
    var account = Account(name: "Offline", kind: .codex)
    account.expectedIdentity = "fixture@example.com"
    let snapshot = Snapshot(observedAt: Date(), windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 27, durationMinutes: 10_080)], identity: account.expectedIdentity, source: "Fixture")
    store.accounts = [account]; store.snapshots[account.id] = snapshot
    let cache = SnapshotCache(root: root)
    let history = try cache.save(snapshot, for: account)
    store.refresh(force: true)
    try await waitUntil { !store.refreshing }
    #expect(store.errors[account.id] != nil)
    #expect(store.snapshots[account.id]?.observedAt == snapshot.observedAt)
    #expect(store.menuEntries.first?.remainingPercent == 73)
    #expect(store.menuEntries.first?.isLastKnown == true)
    #expect(cache.loadHistory(accounts: [account])[account.id] == history)
    store.errors[account.id] = nil
    #expect(store.menuEntries.first?.isLastKnown == false)
    await store.shutdown()
}

private actor RefreshConcurrencyProbe {
    var active = 0
    var maximum = 0
    func fetch(_ account: Account, at date: Date) async throws -> Snapshot {
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: account.name == "Slow" ? .milliseconds(800) : .milliseconds(30))
        return Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 20, durationMinutes: 10_080)], identity: account.id.uuidString + "@example.com", source: "Fixture")
    }
}

@Test @MainActor func slowAccountDoesNotBlockFastReadingAndConcurrencyIsBounded() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let probe = RefreshConcurrencyProbe()
    let store = AppStore(root: root, monitor: false, fetch: { account, date in try await probe.fetch(account, at: date) })
    var slow = Account(name: "Slow", kind: .codex)
    var fast = Account(name: "Fast", kind: .codex)
    var third = Account(name: "Third", kind: .codex)
    slow.expectedIdentity = slow.id.uuidString + "@example.com"
    fast.expectedIdentity = fast.id.uuidString + "@example.com"
    third.expectedIdentity = third.id.uuidString + "@example.com"
    store.accounts = [slow, fast, third]
    store.refresh(force: true)
    try await waitUntil { store.snapshots[third.id] != nil }
    #expect(store.snapshots[slow.id] == nil)
    #expect(store.snapshots[fast.id] != nil)
    #expect(store.refreshingAccounts.contains(slow.id))
    #expect(!store.refreshingAccounts.contains(fast.id))
    #expect(await probe.maximum == 2)
    await store.shutdown()
    #expect(store.snapshots[slow.id] == nil)
    #expect(store.refreshingAccounts.isEmpty)
}

private actor RecoveryProbe {
    var attempts = 0
    let firstError: UsageError
    init(_ error: UsageError) { firstError = error }
    func fetch(_ account: Account, date: Date) throws -> Snapshot {
        attempts += 1
        if attempts == 1 { throw firstError }
        return Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 20, durationMinutes: 10_080)], identity: "recovery@example.com", source: "Fixture")
    }
}
@Test @MainActor func reconnectingNetworkRetriesTimeoutButRespectsProviderBackoff() async throws {
    for failure in [UsageError.timeout, UsageError.rateLimited(600)] {
        let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = RecoveryProbe(failure)
        let store = AppStore(root: root, monitor: false, fetch: { account, date in try await probe.fetch(account, date: date) })
        let account = Account(name: "Test", kind: .codex); store.accounts = [account]
        store.refresh(force: true)
        try await waitUntil { !store.refreshing }
        #expect(store.errors[account.id] != nil)
        store.updateConnectivity(offline: true); store.updateConnectivity(offline: false)
        try await waitUntil { !store.refreshing }
        if failure == .timeout {
            #expect(await probe.attempts == 2)
            #expect(store.errors[account.id] == nil)
            #expect(store.connectionState(account).title == "Available")
        } else {
            #expect(await probe.attempts == 1)
            #expect(store.connectionState(account).title == "Provider busy")
        }
        await store.shutdown()
    }
}

@Test @MainActor func historyWriteFailureIsVisibleWithoutDiscardingLiveUsage() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    // A non-directory at the cache path deterministically simulates unwritable storage.
    try Data("fixture".utf8).write(to: root.appendingPathComponent("Readings"))
    let store = AppStore(root: root, monitor: false, fetch: { _, date in
        Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 17, durationMinutes: 10_080)], identity: "fixture@example.com", source: "Fixture")
    })
    let account = Account(name: "Test", kind: .codex); store.accounts = [account]
    store.refresh(force: true)
    try await waitUntil { !store.refreshing && store.notice != nil }
    #expect(store.snapshots[account.id]?.displayWindow(for: .codex)?.remainingPercent == 83)
    #expect(store.errors[account.id] == nil)
    #expect(store.history(for: account).count == 1)
    #expect(store.notice?.contains("could not be saved") == true)
    #expect(store.notice?.contains(root.path) == false)
    await store.shutdown()
}

@Test @MainActor func duplicateNewAccountsBindInOrderDespiteDifferentProviderLatency() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { account, date in
        if account.name == "First" { try await Task.sleep(for: .milliseconds(100)) }
        return Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 20, durationMinutes: 10_080)], identity: "same@example.com", source: "Fixture")
    })
    let first = Account(name: "First", kind: .codex), second = Account(name: "Second", kind: .codex)
    store.accounts = [first, second]
    store.refresh(force: true)
    try await waitUntil { !store.refreshing }
    #expect(store.snapshots[first.id] != nil)
    #expect(store.snapshots[second.id] == nil)
    #expect(store.errors[second.id] == UsageError.duplicateAccount("First").localizedDescription)
    #expect(store.needsSignIn(second))
    await store.shutdown()
}

@Test @MainActor func retryTargetsOnlySelectedAccountAndBypassesTransientDelay() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.timeout })
    let first = Account(name: "First", kind: .codex)
    let second = Account(name: "Second", kind: .claudeCode)
    store.accounts = [first, second]
    store.refresh()
    try await waitUntil { !store.refreshing }
    store.errors[second.id] = "Untouched sentinel"
    store.retryConnection(first)
    #expect(store.refreshing)
    try await waitUntil { !store.refreshing }
    #expect(store.errors[second.id] == "Untouched sentinel")
    await store.shutdown()
}

@Test @MainActor func explicitAccountRetryHonorsRateLimit() async throws {
    let root = try reliabilityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.rateLimited(3600) })
    let account = Account(name: "Limited", kind: .codex)
    store.accounts = [account]; store.refresh()
    try await waitUntil { !store.refreshing }
    store.retryConnection(account)
    #expect(!store.refreshing)
    #expect(store.notice?.contains("provider asked us to wait") == true)
    await store.shutdown()
}
