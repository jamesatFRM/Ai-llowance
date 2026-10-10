import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func identityRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Identity-\(UUID().uuidString)")
    try Paths.prepare(root)
    return root
}
@MainActor private func finish(_ store: AppStore) async throws {
    let deadline = Date().addingTimeInterval(5)
    while store.refreshing {
        guard Date() < deadline else { throw UsageError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func reading(_ email: String, at date: Date) throws -> Snapshot {
    Snapshot(observedAt: date, windows: [try QuotaWindow(id: "codex.Secondary", label: "Week", usedPercent: 20,
        resetsAt: date.addingTimeInterval(86400), durationMinutes: 10080)], identity: email, source: "Fixture")
}

@Test @MainActor func distinctCodexConnectionsBindIdentitiesAndSurviveRestart() async throws {
    let root = try identityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let a = Account(name: "Personal", kind: .codex, usesExistingCodex: true)
    let b = Account(name: "Work", kind: .codex)
    let store = AppStore(root: root, monitor: false, fetch: { account, date in
        try reading(account.id == a.id ? " Personal@Example.com " : "work@example.com", at: date)
    })
    store.accounts = [a,b]; store.refresh(); try await finish(store)
    #expect(store.errors.isEmpty)
    #expect(store.accounts.map(\.expectedIdentity) == ["personal@example.com", "work@example.com"])
    let restored = AppStore(root: root, monitor: false)
    #expect(restored.accounts.map(\.expectedIdentity) == ["personal@example.com", "work@example.com"])
    #expect(restored.accounts.map(\.id) == [a.id, b.id])
}

@Test @MainActor func repeatedCodexEmailCannotBecomeTwoMenuAllowances() async throws {
    let root = try identityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let a = Account(name: "Personal", kind: .codex, usesExistingCodex: true)
    let b = Account(name: "Work", kind: .codex)
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try reading("same@example.com", at: date) })
    store.accounts = [a,b]; store.setMenuDisplay(.byAccount)
    store.refresh(); try await finish(store)
    #expect(store.snapshots[a.id] != nil)
    #expect(store.snapshots[b.id] == nil)
    #expect(store.needsSignIn(b))
    #expect(store.errors[b.id] == UsageError.duplicateAccount("Personal").localizedDescription)
    #expect(store.menuEntries.map(\.remainingPercent) == [80, nil])
    store.setMenuDisplay(.combined)
    #expect(store.menuEntries.first?.remainingPercent == nil)
}

@Test @MainActor func cliAccountSwitchCannotReplaceAPinnedAccount() async throws {
    let root = try identityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Work", kind: .codex, usesExistingCodex: true)
    account.expectedIdentity = "work@example.com"
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try reading("personal@example.com", at: date) })
    store.accounts = [account]
    store.snapshots[account.id] = try reading("work@example.com", at: Date())
    store.refresh(); try await finish(store)
    #expect(store.snapshots[account.id] == nil)
    #expect(store.accounts.first?.expectedIdentity == "work@example.com")
    #expect(store.needsSignIn(account))
    #expect(store.errors[account.id] == UsageError.accountChanged("work@example.com").localizedDescription)
}

private actor IdentityProvider {
    var email = "wrong@example.com"
    func use(_ email: String) { self.email = email }
    func fetch(at date: Date) throws -> Snapshot { try reading(email, at: date) }
}
@Test @MainActor func expectedAccountCanRecoverWithoutChangingConnectionOrPreferences() async throws {
    let root = try identityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Work", kind: .codex); account.expectedIdentity = "work@example.com"
    let provider = IdentityProvider()
    let store = AppStore(root: root, monitor: false, fetch: { _, date in try await provider.fetch(at: date) })
    store.accounts = [account]; store.setShowAccountNames(false)
    store.refresh(); try await finish(store)
    #expect(store.needsSignIn(account))
    await provider.use("WORK@example.com")
    store.retryConnection(account); try await finish(store)
    #expect(store.errors.isEmpty)
    #expect(!store.needsSignIn(account))
    #expect(store.snapshots[account.id]?.identity == "WORK@example.com")
    #expect(store.accounts.first?.id == account.id)
    #expect(!store.menuPreferences.showAccountNames)
}
