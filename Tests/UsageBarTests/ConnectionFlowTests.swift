import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func fixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionFlow-\(UUID().uuidString)")
    try Paths.prepare(root)
    return root
}
private func cli(_ root: URL, _ body: String) throws -> URL {
    let url = root.appendingPathComponent("fake-cli")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}
@MainActor private func settle(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw UsageError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private actor FetchGate {
    var continuation: CheckedContinuation<Snapshot, any Error>?
    var entered = false
    func fetch() async throws -> Snapshot {
        entered = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: Snapshot) { continuation?.resume(returning: value); continuation = nil }
}

@Test @MainActor func temporaryClaudeAuthFailureDoesNotOpenLoginOrAddAnAccount() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var opened = false
    let store = AppStore(root: root, monitor: false, openExternal: { _ in opened = true; return true })
    store.existingClaudeConfig = root.appendingPathComponent("existing")
    store.claudeExecutable = try cli(root, "printf 'not-json'; exit 1")
    store.connectClaude(existing: true)
    try await settle { !store.connectingClaude }
    #expect(!opened)
    #expect(store.accounts.isEmpty)
    #expect(store.notice != nil)
}

@Test @MainActor func failedTerminalLaunchLeavesAnObviousRetryAndNoWaitingState() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, openExternal: { _ in false })
    store.paused = true
    store.claudeExecutable = try cli(root, "exit 0")
    store.connectClaude(existing: false)
    try await settle { !store.connectingClaude }
    let account = try #require(store.accounts.first)
    #expect(store.waitingForClaude.isEmpty)
    #expect(store.needsSignIn(account))
    #expect(store.errors[account.id]?.contains("Could not open Terminal") == true)
}

@Test @MainActor func completingClaudeLoginImmediatelyClearsAuthenticationBackoff() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { account, date in
        Snapshot(observedAt: date, identity: "fixture@example.com", source: "Isolated test")
    }, openExternal: { _ in true })
    store.claudeExecutable = try cli(root, "exit 0")
    let account = try store.add(name: "Claude", kind: .claudeCode, secret: "", existing: false, refreshAfter: false)
    store.openClaude(account, login: true)
    #expect(store.waitingForClaude[account.id] != nil)
    let folder = root.appendingPathComponent("ClaudeConnections/\(account.id.uuidString)")
    let script = try String(contentsOf: folder.appendingPathComponent("Connect Claude.command"), encoding: .utf8)
    #expect(script.contains("trap usagebar_finished EXIT"))
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", folder.appendingPathComponent("Connect Claude.command").path]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    store.refresh()
    try await settle { !store.refreshing }
    #expect(store.waitingForClaude.isEmpty)
    #expect(store.snapshots[account.id]?.identity == "fixture@example.com")
    #expect(!store.needsSignIn(account))
}

@Test @MainActor func reconnectDiscardsAnOlderRefreshResult() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let gate = FetchGate()
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in try await gate.fetch() }, openExternal: { _ in true })
    store.claudeExecutable = try cli(root, "exit 0")
    let account = try store.add(name: "Claude", kind: .claudeCode, secret: "", existing: false, refreshAfter: false)
    store.refresh()
    while !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
    store.openClaude(account, login: true)
    await gate.finish(Snapshot(observedAt: Date(), identity: "old@example.com", source: "Old request"))
    try await settle { !store.refreshing }
    #expect(store.snapshots[account.id] == nil)
    #expect(store.waitingForClaude[account.id] != nil)
    #expect(store.claudeSignedIn[account.id] == false)
    store.cancelClaudeSignIn(account)
}

@Test @MainActor func failedAccountDoesNotBlockOtherAccountsAndRetryKeepsRateLimitBackoff() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let failed = Account(name: "Failed", kind: .codex)
    let healthy = Account(name: "Healthy", kind: .codex)
    let store = AppStore(root: root, monitor: false, fetch: { account, date in
        if account.id == failed.id { throw UsageError.rateLimited(900) }
        return Snapshot(observedAt: date, identity: "healthy@example.com", source: "Fixture")
    })
    store.accounts = [failed, healthy]
    store.refresh()
    try await settle { !store.refreshing }
    #expect(store.errors[failed.id] != nil)
    #expect(store.snapshots[healthy.id]?.identity == "healthy@example.com")
    #expect(!store.authenticationRequired.contains(failed.id))
    store.retryConnection(failed)
    #expect(!store.refreshing)
}

@Test @MainActor func expiredCodexLoginShowsRecoveryEvenWhenLastReadingExists() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let account = Account(name: "Codex", kind: .codex)
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.authentication })
    store.accounts = [account]
    store.snapshots[account.id] = Snapshot(observedAt: Date(), source: "Previous reading")
    store.refresh(); try await settle { !store.refreshing }
    #expect(store.snapshots[account.id] != nil)
    #expect(store.needsSignIn(account))
}

@Test @MainActor func abandonedClaudeLoginTimesOutAndCanBeRetried() throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, openExternal: { _ in true })
    store.claudeExecutable = try cli(root, "exit 0")
    let account = try store.add(name: "Claude", kind: .claudeCode, secret: "", existing: false, refreshAfter: false)
    store.openClaude(account, login: true)
    store.checkClaudeSignIns(at: Date().addingTimeInterval(601))
    #expect(store.waitingForClaude.isEmpty)
    #expect(store.needsSignIn(account))
    #expect(store.errors[account.id]?.contains("not completed") == true)
    store.openClaude(account, login: true)
    #expect(store.waitingForClaude[account.id] != nil)
    store.cancelClaudeSignIn(account)
}

@Test @MainActor func duplicateLabelsAreAvoidedAndDuplicateEmailsAreVisible() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, openExternal: { _ in true })
    store.paused = true; store.claudeExecutable = try cli(root, "exit 0")
    let previous = try store.add(name: "Claude 2", kind: .claudeCode, secret: "", existing: false, refreshAfter: false)
    store.connectClaude(existing: false); try await settle { !store.connectingClaude }
    let next = try #require(store.accounts.last)
    #expect(next.name != previous.name)
    store.snapshots[previous.id] = Snapshot(observedAt: Date(), identity: "Same@example.com", source: "Fixture")
    store.snapshots[next.id] = Snapshot(observedAt: Date(), identity: "same@example.com", source: "Fixture")
    #expect(store.duplicateIdentity(next) == previous.name)
    store.cancelClaudeSignIn(next)
}

@Test @MainActor func existingClaudeAPILoginIsNotReplacedBySubscriptionSetup() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, openExternal: { _ in true })
    store.paused = true
    store.existingClaudeConfig = root.appendingPathComponent("existing")
    try Paths.prepare(store.existingClaudeConfig)
    let existing = store.existingClaudeConfig.appendingPathComponent("settings.json")
    let original = Data(#"{"custom":"unchanged"}"#.utf8); try original.write(to: existing)
    store.claudeExecutable = try cli(root, "printf '%s' '{\"loggedIn\":true,\"authMethod\":\"api_key\"}'")
    store.connectClaude(existing: true)
    try await settle { !store.connectingClaude }
    let account = try #require(store.accounts.first)
    #expect(account.usesExistingClaude == false)
    #expect(try Data(contentsOf: existing) == original)
    #expect(store.waitingForClaude[account.id] != nil)
    store.connectClaude(existing: true)
    #expect(store.accounts.count == 1) // Repeated clicks while signing in cannot create duplicates.
    store.cancelClaudeSignIn(account)
}

@Test @MainActor func cancellingCodexLoginPreservesRetryInsteadOfOverwritingItWithARefreshError() async throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in throw UsageError.authentication }, openExternal: { _ in true })
    store.executable = try cli(root, """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'account/login/start'*) printf '%s\\n' '{"id":2,"result":{"authUrl":"https://auth.openai.com/fixture","loginId":"one"}}' ;;
      esac
    done
    """)
    let account = try store.add(name: "OpenAI", kind: .codex, secret: "", existing: false, refreshAfter: false)
    store.signIn(account)
    try await Task.sleep(for: .milliseconds(100))
    store.cancelSignIn()
    try await settle { store.signingIn == nil && !store.refreshing }
    #expect(store.errors[account.id]?.contains("cancelled") == true)
    #expect(store.needsSignIn(account))
}

@Test @MainActor func corruptSettingsArePreservedAndAddingAccountsFailsClosed() throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("accounts.json")
    let original = Data("broken settings".utf8); try original.write(to: url)
    let store = AppStore(root: root, monitor: false, openExternal: { _ in Issue.record("Must not open login"); return false })
    #expect(throws: UsageError.storage) { try store.add(name: "Test", kind: .codex, secret: "", existing: false) }
    store.connectClaude(existing: false)
    store.connectOpenAI()
    #expect(try Data(contentsOf: url) == original)
    #expect(store.accounts.isEmpty)
}

@Test @MainActor func offlineAndPausedStatesDoNotStartReads() throws {
    let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false, fetch: { _, _ in
        Issue.record("Paused/offline accounts must not read providers")
        throw UsageError.server
    })
    store.accounts = [Account(name: "Test", kind: .codex)]
    store.offline = true; store.refresh(force: true)
    #expect(!store.refreshing)
    store.offline = false; store.paused = true; store.refresh(force: true)
    #expect(!store.refreshing)
}
