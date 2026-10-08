import Foundation
import Darwin
import Testing
@testable import UsageCore

private struct PressureFixture {
    let root: URL
    let executable: URL
    init(_ script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Pressure fixture's \(UUID().uuidString)")
        try Paths.prepare(root)
        executable = root.appendingPathComponent("provider")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func connection() -> ClaudeConnection {
        ClaudeConnection(root: root, executable: executable, bundledBridge: executable, existingConfig: root.appendingPathComponent("existing"))
    }
}
private actor OpenedLinks {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}
private func loginServer(_ reply: String, beforeReply: String = "", afterReply: String = "") -> String {
    """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'account/login/start'*)
          \(beforeReply)
          printf '%s\\n' \(ShellQuote.argument(reply))
          \(afterReply)
          ;;
        *) exit 9 ;;
      esac
    done
    """
}
private let startReply = #"{"id":2,"result":{"authUrl":"https://auth.openai.com/authorize?fixture=true","loginId":"expected"}}"#
private let successNotice = #"{"method":"account/login/completed","params":{"loginId":"expected","success":true}}"#

@Test func codexLoginAcceptsEarlyCompletionAndIgnoresAnotherLoginID() async throws {
    let other = #"{"method":"account/login/completed","params":{"loginId":"other","success":false}}"#
    let fixture = try PressureFixture(loginServer(startReply,
        beforeReply: "printf '%s\\n' \(ShellQuote.argument(other)) \(ShellQuote.argument(successNotice))"))
    defer { fixture.clean() }
    let urls = OpenedLinks()
    try await CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 2)
        .login(account: Account(name: "Fixture", kind: .codex)) { await urls.append($0) }
    #expect(await urls.urls.count == 1)
    #expect(await urls.urls.first?.host == "auth.openai.com")
}

@Test func codexRejectsUntrustedLoginDestinationsWithoutOpeningBrowser() async throws {
    for url in ["http://auth.openai.com/login", "https://auth.openai.com.evil.example/login", "file:///tmp/login"] {
        let reply = try JSONSerialization.data(withJSONObject: ["id": 2, "result": ["authUrl": url, "loginId": "expected"]])
        let fixture = try PressureFixture(loginServer(String(decoding: reply, as: UTF8.self)))
        defer { fixture.clean() }
        let urls = OpenedLinks()
        await #expect(throws: UsageError.invalidData) {
            try await CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 2)
                .login(account: Account(name: "Fixture", kind: .codex)) { await urls.append($0) }
        }
        #expect(await urls.urls.isEmpty)
    }
}

@Test func codexFailedLoginAndBrowserFailureReturnActionableErrors() async throws {
    let failed = #"{"method":"account/login/completed","params":{"loginId":"expected","success":false,"error":"PRIVATE TOKEN NOT FOR UI"}}"#
    let fixture = try PressureFixture(loginServer(startReply, afterReply: "printf '%s\\n' \(ShellQuote.argument(failed))"))
    defer { fixture.clean() }
    let adapter = CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 2)
    await #expect(throws: UsageError.authentication) {
        try await adapter.login(account: Account(name: "Fixture", kind: .codex)) { _ in }
    }
    await #expect(throws: UsageError.unavailable("Browser unavailable")) {
        try await adapter.login(account: Account(name: "Fixture", kind: .codex)) { _ in throw UsageError.unavailable("Browser unavailable") }
    }
}

@Test func codexAbandonedLoginTimesOutAndCancellationStopsPromptly() async throws {
    let fixture = try PressureFixture(loginServer(startReply)); defer { fixture.clean() }
    let account = Account(name: "Fixture", kind: .codex)
    let started = Date()
    await #expect(throws: UsageError.timeout) {
        try await CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 0.15)
            .login(account: account) { _ in }
    }
    let task = Task {
        try await CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 30)
            .login(account: account) { _ in }
    }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func codexSeparateLoginsUseDifferentProfilesAndKeychainOnly() async throws {
    let fixture = try PressureFixture("""
    printf '%s|%s|%s|%s\\n' "$CODEX_HOME" "$*" "${OPENAI_API_KEY-unset}" "${ANTHROPIC_API_KEY-unset}" >> "$CODEX_HOME/calls"
    \(loginServer(startReply, afterReply: "printf '%s\\n' \(ShellQuote.argument(successNotice))"))
    """)
    defer { fixture.clean() }
    let adapter = CodexAdapter(executable: fixture.executable, root: fixture.root, loginTimeout: 2)
    let a = Account(name: "Same label", kind: .codex); let b = Account(name: "Same label", kind: .codex)
    for account in [a,b] {
        try await adapter.login(account: account) { _ in }
        let calls = try String(contentsOf: adapter.home(account).appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("cli_auth_credentials_store=\"keyring\""))
        #expect(calls.hasSuffix("|unset|unset\n"))
    }
    #expect(adapter.home(a) != adapter.home(b))
}

@Test func claudeCommandWithClosedOutputStillTimesOutAndOversizedOutputIsRejected() throws {
    let fixture = try PressureFixture("exec 1>&-\nexec /bin/sleep 30"); defer { fixture.clean() }
    let process = Process(); let output = Pipe()
    process.executableURL = fixture.executable; process.standardOutput = output
    try process.run()
    #expect(throws: UsageError.timeout) { try CommandOutput.read(process, output: output, timeout: 0.15, limit: 100) }
    process.waitUntilExit()
    #expect(!process.isRunning)
    let second = Process(); let pipe = Pipe()
    second.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
    second.arguments = [String(repeating: "x", count: 1000)]; second.standardOutput = pipe
    try second.run()
    #expect(throws: UsageError.invalidData) { try CommandOutput.read(second, output: pipe, timeout: 1, limit: 64) }
}

@Test func claudeNonzeroExitCannotClaimSuccessfulAuthenticationOrUsage() async throws {
    let fixture = try PressureFixture("printf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}'; exit 7")
    defer { fixture.clean() }
    await #expect(throws: UsageError.server) {
        try await fixture.connection().authIdentity(account: Account(name: "Fixture", kind: .claudeCode))
    }
    let report = try JSONSerialization.data(withJSONObject: ["type":"result", "subtype":"success", "is_error":false,
        "num_turns":0,"total_cost_usd":0,"result":"Current session: 10% used\nCurrent week (all models): 20% used"])
    try ("#!/bin/sh\nif [ \"$1\" = auth ]; then printf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}'; else printf '%s' " + ShellQuote.argument(String(decoding: report, as: UTF8.self)) + "; exit 7; fi\n")
        .write(to: fixture.executable, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) {
        try await ClaudeUsageAdapter(executable: fixture.executable, root: fixture.root)
            .fetch(account: Account(name: "Fixture", kind: .claudeCode), now: Date())
    }
}

@Test func claudeLoggedOutReportIsRecognizedEvenWithNonzeroExitAndNoAuthMethod() async throws {
    let fixture = try PressureFixture("printf '%s' '{\"loggedIn\":false}'; exit 1"); defer { fixture.clean() }
    #expect(try await !fixture.connection().authStatus(account: Account(name: "Fixture", kind: .claudeCode)))
}

@Test func claudeLoginCompletionReportsFailurePrivatelyWithoutClaimingSuccess() throws {
    let fixture = try PressureFixture("exit 9"); defer { fixture.clean() }
    let result = fixture.root.appendingPathComponent("completion")
    let account = Account(name: "Fixture", kind: .claudeCode)
    let launcher = try fixture.connection().launcher(account: account, login: true, loginOnly: true, completion: result)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-f", launcher.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 9)
    #expect(try String(contentsOf: result, encoding: .utf8) == "9\n")
    let permissions = try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func claudeAppOwnedProfileRejectsPlaintextBeforeInvokingCLI() async throws {
    let fixture = try PressureFixture("exit 99"); defer { fixture.clean() }
    let account = Account(name: "Fixture", kind: .claudeCode)
    let profile = fixture.connection().config(account); try Paths.prepare(profile)
    try Data("dummy only".utf8).write(to: profile.appendingPathComponent(".credentials.json"))
    await #expect(throws: UsageError.storage) { try await fixture.connection().authIdentity(account: account) }
}
