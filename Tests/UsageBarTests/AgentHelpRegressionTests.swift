import Foundation
import Testing
import UsageCore
@testable import UsageBar

private func helpRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHelpRegression-\(UUID().uuidString)")
    try Paths.prepare(root); return root
}

@Test(arguments: [ConnectionKind.codex, .claudeCode]) @MainActor
func setupHelpKeepsTheSelectedSubscriptionRatherThanInheritedAPIBilling(kind: ConnectionKind) async throws {
    let root = try helpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let report = root.appendingPathComponent("observed.txt")
    let fake = root.appendingPathComponent("fake-cli")
    let variables = kind == .codex
        ? ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"]
        : ["ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_PROFILE"]
    let lines = variables.map { "printf '%s\\n' \"${\($0)-<unset>}\"" }.joined(separator: "\n")
    try Paths.writePrivate(Data(("#!/bin/sh\n{\n" + lines + "\nprintf '%s\\n' \"$@\"\n} > " + ShellQuote.argument(report.path) + "\n").utf8), to: fake, executable: true)
    var launcher: URL?
    let store = AppStore(root: root, monitor: false, openExternal: { launcher = $0; return true })
    store.paused = true
    store.claudeExecutable = fake; store.executable = fake
    let account = try store.add(name: "Fixture", kind: kind, secret: "", existing: false, refreshAfter: false)
    store.openAgentHelp(for: kind, account: account)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", try #require(launcher).path]
    process.environment = Dictionary(uniqueKeysWithValues: variables.map { ($0, "fixture-inherited-routing") })
    process.environment?["HOME"] = root.path
    process.environment?["PATH"] = "/usr/bin:/bin"
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let observed = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(Array(observed.prefix(variables.count)) == Array(repeating: "<unset>", count: variables.count))
    if kind == .codex {
        #expect(Array(observed.dropFirst(variables.count)) == ["-c", "cli_auth_credentials_store=\"keyring\""])
    }
    await store.shutdown()
}

@Test @MainActor func selectingTheSameAccountAgainIssuesAnotherNavigationRequest() async throws {
    let root = try helpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Fixture", kind: .codex)
    store.accounts = [account]
    let initial = store.accountNavigationVersion
    store.selectedAccountID = account.id
    #expect(store.accountNavigationVersion == initial + 1)
    // The user can leave Accounts and click the same attention item again.
    store.selectedAccountID = account.id
    #expect(store.accountNavigationVersion == initial + 2)
    store.selectedAccountID = nil
    #expect(store.accountNavigationVersion == initial + 2)
    await store.shutdown()
}

@Test @MainActor func existingCodexHelpPreservesItsOwnCredentialStoreConfiguration() async throws {
    let root = try helpRoot(); defer { try? FileManager.default.removeItem(at: root) }
    var launcher: URL?
    let store = AppStore(root: root, monitor: false, openExternal: { launcher = $0; return true })
    let fake = root.appendingPathComponent("fake-cli")
    try Paths.writePrivate(Data("#!/bin/sh\nexit 0\n".utf8), to: fake, executable: true)
    store.executable = fake
    let account = try store.add(name: "Existing", kind: .codex, secret: "", existing: true, refreshAfter: false)
    store.openAgentHelp(for: .codex, account: account)
    let script = try String(contentsOf: try #require(launcher), encoding: .utf8)
    #expect(!script.contains("cli_auth_credentials_store"))
    await store.shutdown()
}
