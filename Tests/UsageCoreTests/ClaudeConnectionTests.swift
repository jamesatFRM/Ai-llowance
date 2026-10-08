import Foundation
import Testing
@testable import UsageCore

private struct SetupFixture {
    let root: URL
    let config: URL
    let bridge: URL
    let cli: URL
    let connection: ClaudeConnection
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBar fixture's \(UUID().uuidString)")
        config = root.appendingPathComponent("existing claude")
        bridge = root.appendingPathComponent("bridge")
        cli = root.appendingPathComponent("claude")
        try Paths.prepare(config)
        try "#!/bin/sh\ncat >/dev/null\nprintf 'BRIDGE-OUTPUT'\n".write(to: bridge, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
        for path in [bridge, cli] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
        connection = ClaudeConnection(root: root.appendingPathComponent("app data"), executable: cli, bundledBridge: bridge, existingConfig: config)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: config.appendingPathComponent("settings.json"))) as! [String: Any]
    }
    func save(_ settings: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appendingPathComponent("settings.json"))
    }
}

@Test func automaticClaudeSetupPreservesCustomOutputAndRestoresOnlyItsOwnSetting() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let account = Account(name: "Work", kind: .claudeCode, usesExistingClaude: true)
    try fixture.save(["theme": "dark", "statusLine": ["type": "command", "command": "cat", "padding": 3]])
    try fixture.connection.install(account: account)
    let installed = try fixture.settings()
    #expect(installed["theme"] as? String == "dark")
    let status = installed["statusLine"] as! [String: Any]
    #expect(status["padding"] as? Int == 3)
    let command = status["command"] as! String
    let process = Process(); let input = Pipe(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
    process.standardInput = input; process.standardOutput = output
    try process.run()
    let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":37}},"session_id":"fixture"}"#.utf8)
    try input.fileHandleForWriting.write(contentsOf: payload); try input.fileHandleForWriting.close()
    let returned = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    #expect(returned == payload)
    #expect(process.terminationStatus == 0)
    // Reconnect is idempotent rather than wrapping the wrapper again.
    try fixture.connection.install(account: account)
    #expect((try fixture.settings()["statusLine"] as? [String: Any])?["command"] as? String == command)
    var changed = try fixture.settings(); changed["theme"] = "light"; try fixture.save(changed)
    try fixture.connection.uninstall(account: account)
    let restored = try fixture.settings()
    #expect(restored["theme"] as? String == "light")
    #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat")
}

@Test func removingClaudeConnectionPreservesLaterUserChanges() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let account = Account(name: "Personal", kind: .claudeCode, usesExistingClaude: true)
    try fixture.connection.install(account: account)
    var settings = try fixture.settings()
    settings["statusLine"] = ["type": "command", "command": "printf newer"]
    try fixture.save(settings)
    try fixture.connection.uninstall(account: account)
    #expect((try fixture.settings()["statusLine"] as? [String: Any])?["command"] as? String == "printf newer")
}

@Test func invalidClaudeSettingsAreNeverOverwritten() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let url = fixture.config.appendingPathComponent("settings.json")
    let original = Data("not valid json".utf8); try original.write(to: url)
    #expect(throws: (any Error).self) { try fixture.connection.install(account: Account(name: "x", kind: .claudeCode, usesExistingClaude: true)) }
    #expect(try Data(contentsOf: url) == original)
}

@Test func oneClickLauncherUsesIsolatedLoginWithoutSendingAPrompt() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let log = fixture.root.appendingPathComponent("calls.txt")
    let fakeCLI = """
    #!/bin/sh
    printf '%s|%s\\n' "$CLAUDE_CONFIG_DIR" "$*" >> \(ShellQuote.argument(log.path))
    """
    try fakeCLI.write(to: fixture.cli, atomically: true, encoding: .utf8)
    let first = Account(name: "Name $(not-a-command)", kind: .claudeCode)
    let second = Account(name: "Work", kind: .claudeCode)
    #expect(fixture.connection.config(first) != fixture.connection.config(second))
    try fixture.connection.install(account: first)
    let launcher = try fixture.connection.launcher(account: first, login: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-f", launcher.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    let profile = fixture.connection.config(first).path
    #expect(calls == ["\(profile)|auth login --claudeai", "\(profile)|"])
    #expect(!FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("settings.json").path))
}

@Test func newClaudeLoginRejectsProviderPlaintextFallback() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let account = Account(name: "New", kind: .claudeCode)
    try fixture.connection.install(account: account)
    let fallback = fixture.connection.config(account).appendingPathComponent(".credentials.json")
    try Data("dummy-test-only".utf8).write(to: fallback)
    let log = fixture.root.appendingPathComponent("logout.txt")
    try "#!/bin/sh\nprintf '%s' \"$*\" > \(ShellQuote.argument(log.path))\n".write(to: fixture.cli, atomically: true, encoding: .utf8)
    let launcher = try fixture.connection.launcher(account: account, login: false)
    let process = Process(); let input = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-f", launcher.path]
    process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8)); try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus != 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "auth logout")
}

@Test func claudeAuthStatusDistinguishesSignInFromQuotaAvailability() async throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let account = Account(name: "Existing", kind: .claudeCode, usesExistingClaude: true)
    for (json, expected) in [
        (#"{"loggedIn":false,"authMethod":"none"}"#, false),
        (#"{"loggedIn":true,"authMethod":"api_key"}"#, false),
        (#"{"loggedIn":true,"authMethod":"claude.ai"}"#, true)
    ] {
        try "#!/bin/sh\nprintf '%s' \(ShellQuote.argument(json))\n".write(to: fixture.cli, atomically: true, encoding: .utf8)
        #expect(try await fixture.connection.authStatus(account: account) == expected)
    }
    #expect(!FileManager.default.fileExists(atPath: Paths.feed(account.id, root: fixture.connection.root).path))
}

@Test func claudeAuthCheckSuppliesMacOSKeychainUsername() async throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let script = """
    #!/bin/sh
    if [ "$USER" = \(ShellQuote.argument(NSUserName())) ]; then
      printf '%s' '{"loggedIn":true,"authMethod":"claude.ai"}'
    else
      printf '%s' '{"loggedIn":false,"authMethod":"none"}'
    fi
    """
    try script.write(to: fixture.cli, atomically: true, encoding: .utf8)
    let account = Account(name: "Keychain", kind: .claudeCode, usesExistingClaude: true)
    #expect(try await fixture.connection.authStatus(account: account))
}

@Test func claudeLoginOnlyLauncherStopsAfterSignInWithoutStartingConversation() throws {
    let fixture = try SetupFixture(); defer { fixture.cleanup() }
    let log = fixture.root.appendingPathComponent("login-calls")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ShellQuote.argument(log.path))\n".write(to: fixture.cli, atomically: true, encoding: .utf8)
    let account = Account(name: "New", kind: .claudeCode)
    let launcher = try fixture.connection.launcher(account: account, login: true, loginOnly: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-f", launcher.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "auth login --claudeai\n")
    #expect(!FileManager.default.fileExists(atPath: fixture.connection.config(account).appendingPathComponent("settings.json").path))
}
