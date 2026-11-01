import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func setupRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SetupTest-\(UUID().uuidString)")
    try Paths.prepare(root); return root
}
@MainActor private func finishSetupRead(_ store: AppStore) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.refreshing {
        guard Date() < deadline else { throw UsageError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func setupSnapshot(_ email: String, at date: Date) throws -> Snapshot {
    Snapshot(observedAt: date, windows: [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 30,
        resetsAt: date.addingTimeInterval(86400), durationMinutes: 10080)], identity: email, source: "Fixture")
}

@Test @MainActor func claudeAccountsBindAndDuplicateCannotCountTwice() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let first = Account(name: "Personal", kind: .claudeCode)
    let duplicate = Account(name: "Work", kind: .claudeCode)
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try setupSnapshot("personal@example.com", at: date) })
    store.accounts = [first, duplicate]; store.setMenuDisplay(.byAccount)
    store.refresh(); try await finishSetupRead(store)
    #expect(store.accounts[0].expectedIdentity == "personal@example.com")
    #expect(store.snapshots[duplicate.id] == nil)
    #expect(store.needsSignIn(duplicate))
    #expect(store.menuEntries.map(\.remainingPercent) == [70, nil])
    await store.shutdown()
}

@Test @MainActor func claudeCLIIdentityChangeKeepsOriginalBindingAndClearsHistory() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Work", kind: .claudeCode, usesExistingClaude: true)
    account.expectedIdentity = "work@example.com"
    try SnapshotCache(root: root).save(setupSnapshot("work@example.com", at: Date()), for: account)
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try setupSnapshot("personal@example.com", at: date) })
    store.accounts = [account]; store.refresh(); try await finishSetupRead(store)
    #expect(store.accounts[0].expectedIdentity == "work@example.com")
    #expect(store.snapshots[account.id] == nil)
    #expect(store.history(for: account).isEmpty)
    #expect(store.needsSignIn(account))
    await store.shutdown()
    #expect(SnapshotCache(root: root).load(accounts: [account]).isEmpty)
}

@Test @MainActor func successfulReadingRestoresImmediatelyAfterRestartWithOriginalTimestamp() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try setupSnapshot("personal@example.com", at: date) })
    let account = try store.add(name: "Personal", kind: .claudeCode, secret: "", existing: true)
    try await finishSetupRead(store)
    let reading = try #require(store.snapshots[account.id])
    await store.shutdown()
    let restored = AppStore(root: root, monitor: false)
    #expect(restored.isCached(account))
    #expect(restored.snapshots[account.id]?.observedAt == reading.observedAt)
    #expect(restored.snapshots[account.id]?.identity == "personal@example.com")
    #expect(restored.history(for: account).count == 1)
    await restored.shutdown()
}

@Test func rememberedExecutableInvalidatesWhenFileChanges() throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tool")
    try Paths.writePrivate(Data("#!/bin/sh\nexit 0\n".utf8), to: file, executable: true)
    let remembered = try #require(RememberedExecutable(url: file))
    #expect(remembered.validatedURL != nil)
    try Paths.writePrivate(Data("#!/bin/sh\necho changed\n".utf8), to: file, executable: true)
    #expect(remembered.validatedURL == nil)
}

@Test(arguments: [false, true]) @MainActor
func removedClaudeCLIStillAllowsAccountRemovalWithoutLosingStatusLine(userEditedLater: Bool) async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("existing-claude")
    let settings = config.appendingPathComponent("settings.json")
    let original = ["statusLine": ["type": "command", "command": "printf original"], "fixture": true] as [String: Any]
    try Paths.writePrivate(JSONSerialization.data(withJSONObject: original), to: settings)
    let bridge = root.appendingPathComponent("fixture-bridge")
    try Paths.writePrivate(Data("fixture bridge; never executed".utf8), to: bridge)
    let missingCLI = root.appendingPathComponent("removed-claude")
    let account = Account(name: "Claude fixture", kind: .claudeCode, usesExistingClaude: true)
    let connection = ClaudeConnection(root: root, executable: missingCLI, bundledBridge: bridge, existingConfig: config)
    _ = try connection.install(account: account)
    if userEditedLater {
        var changed = original
        changed["statusLine"] = ["type": "command", "command": "printf later-edit"]
        try Paths.writePrivate(JSONSerialization.data(withJSONObject: changed), to: settings)
    }
    let store = AppStore(root: root, monitor: false)
    store.existingClaudeConfig = config
    store.claudeExecutable = nil
    store.accounts = [account]
    await store.remove(account)
    #expect(store.accounts.isEmpty)
    #expect(store.notice == nil)
    let result = try #require(JSONSerialization.jsonObject(with: Paths.readData(settings)) as? [String: Any])
    let statusLine = try #require(result["statusLine"] as? [String: String])
    #expect(statusLine["command"] == (userEditedLater ? "printf later-edit" : "printf original"))
    #expect(result["fixture"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ClaudeConnections/\(account.id.uuidString)/setup.json").path))
    await store.shutdown()
}

@Test @MainActor func sharedClaudeCacheCannotAppearAfterRestartOrReconnect() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Personal", kind: .claudeCode, usesExistingClaude: true)
    account.expectedIdentity = "personal@example.com"
    try SnapshotCache(root: root).save(setupSnapshot("personal@example.com", at: Date()), for: account)
    let store = AppStore(root: root, monitor: false)
    store.accounts = [account]
    store.setMenuDisplay(.byProvider) // Change a preference to persist the fixture settings.
    await store.shutdown()
    let reloaded = AppStore(root: root, monitor: false)
    #expect(reloaded.snapshots[account.id] == nil)
    #expect(reloaded.history(for: account).isEmpty)
    #expect(reloaded.needsSignIn(account))
    #expect(reloaded.errors[account.id]?.contains("Reconnect") == true)
    account.usesExistingClaude = false
    #expect(SnapshotCache(root: root).load(accounts: [account]).isEmpty)
    await reloaded.shutdown()
}

@Test @MainActor func verifiedHistorySurvivesIdentityErrorAndRestartWithoutRestoringCurrentReading() async throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try setupSnapshot("personal@example.com", at: date) })
    let account = try store.add(name: "Personal", kind: .claudeCode, secret: "", existing: true)
    try await finishSetupRead(store)
    let bound = try #require(store.accounts.first)
    await store.shutdown()
    let changed = AppStore(root: root, monitor: false, fetch: { _, date in try setupSnapshot("different@example.com", at: date) })
    let original = changed.history(for: bound)
    #expect(original.count == 1)
    changed.refresh(force: true); try await finishSetupRead(changed)
    #expect(changed.snapshots[account.id] == nil)
    #expect(changed.history(for: bound) == original)
    await changed.shutdown()
    let restarted = AppStore(root: root, monitor: false)
    #expect(restarted.snapshots[account.id] == nil)
    #expect(restarted.history(for: bound) == original)
    await restarted.shutdown()
}

@Test func historyKeepsSevenDaysAcrossCacheInstancesAndReconnect() throws {
    let root = try setupRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Personal", kind: .codex)
    account.expectedIdentity = "personal@example.com"
    let start = Date().addingTimeInterval(-7 * 86400)
    for index in 0...2016 {
        let date = start.addingTimeInterval(Double(index * 300))
        try SnapshotCache(root: root).save(setupSnapshot("personal@example.com", at: date), for: account)
    }
    let now = start.addingTimeInterval(7 * 86400)
    let cache = SnapshotCache(root: root)
    let original = try #require(cache.loadHistory(accounts: [account], now: now)[account.id])
    #expect(original.count == 2017)
    try cache.invalidateSnapshot(account, now: now)
    #expect(SnapshotCache(root: root).load(accounts: [account], now: now).isEmpty)
    #expect(SnapshotCache(root: root).loadHistory(accounts: [account], now: now)[account.id] == original)
    let next = now.addingTimeInterval(300)
    try cache.save(setupSnapshot("personal@example.com", at: next), for: account)
    let continued = try #require(cache.loadHistory(accounts: [account], now: next)[account.id])
    #expect(continued.count == 2017)
    #expect(continued.first == original[1])
    #expect(continued.last?.timestamp == next)
    var other = account; other.expectedIdentity = "other@example.com"
    #expect(cache.loadHistory(accounts: [other], now: next).isEmpty)
}
