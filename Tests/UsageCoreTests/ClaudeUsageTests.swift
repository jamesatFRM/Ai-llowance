import Foundation
import Testing
@testable import UsageCore

private let checkTime = ISO8601DateFormatter().date(from: "2026-10-08T17:00:00Z")!
private let planText = """
You are currently using your subscription to power your Claude Code usage

Current session: 38% used · resets Oct 8 at 12:10pm (America/Denver)
Current week (all models): 81% used · resets Oct 13 at 10am (America/Denver)
Current week (Fable): 0% used · resets Oct 13 at 10am (America/Denver)

What's contributing to your limits usage?
97% of your usage came from subagent-heavy sessions
"""
private func envelope(_ text: String, turns: Int = 0, cost: Double = 0) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
        "result": text, "num_turns": turns, "total_cost_usd": cost])
}

@Test func directClaudeUsageKeepsPlanWindowsAndIgnoresAttribution() throws {
    let snapshot = try ClaudeUsageReport.parse(envelope(planText), at: checkTime)
    #expect(snapshot.windows.map(\.usedPercent) == [38, 81, 0])
    #expect(snapshot.windows.map(\.remainingPercent) == [62, 19, 100])
    #expect(snapshot.weeklyWindows.map(\.remainingPercent) == [19, 100])
    #expect(snapshot.windows.map(\.label) == ["Session · 5h", "Week · 7d", "Fable · 7d"])
    #expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-08T18:10:00Z"))
    #expect(snapshot.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2026-10-13T16:00:00Z"))
    #expect(snapshot.observedAt == checkTime)
    #expect(snapshot.source == "Claude Code /usage")
}

@Test func directClaudeUsageRejectsCachedOrInferenceReports() throws {
    for text in ["Showing last-known usage\n" + planText, "Usage endpoint is rate limited\n" + planText] {
        #expect(throws: UsageError.rateLimited(300)) { try ClaudeUsageReport.parse(envelope(text), at: checkTime) }
    }
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope(planText, turns: 1), at: checkTime) }
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope(planText, cost: 0.01), at: checkTime) }
}

@Test func directClaudeUsageNeverSubstitutesBehavioralPercentages() throws {
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope("97% of your usage came from long sessions"), at: checkTime) }
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope("Current week (Fable): 0% used"), at: checkTime) }
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope(planText.replacingOccurrences(of: "38%", with: "138%")), at: checkTime) }
    #expect(throws: (any Error).self) { try ClaudeUsageReport.parse(envelope("Current session: 10% used\n" + planText), at: checkTime) }
}

@Test func directClaudeUsageHandlesNewYearAndUnknownResetFormats() throws {
    let endOfYear = ISO8601DateFormatter().date(from: "2026-12-30T17:00:00Z")!
    #expect(ClaudeUsageReport.resetDate("Jan 2 at 10am (America/Denver)", now: endOfYear) == ISO8601DateFormatter().date(from: "2027-01-02T17:00:00Z"))
    #expect(ClaudeUsageReport.resetDate("sometime tomorrow", now: checkTime) == nil)
    #expect(ClaudeUsageReport.resetDate("Oct 13 at 10am (Invented/Zone)", now: checkTime) == nil)
}

@Test func directClaudeAdapterRunsOnlyAuthAndLocalUsageInSeparateProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeDirect-\(UUID().uuidString)")
    try Paths.prepare(root); defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appendingPathComponent("claude")
    let log = root.appendingPathComponent("calls")
    let payload = String(data: try envelope(planText), encoding: .utf8)!
    let script = """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(ShellQuote.argument(log.path))
    if [ "$1" = auth ]; then
      printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"separate@example.com"}'
    else
      printf '%s' \(ShellQuote.argument(payload))
    fi
    """
    try script.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    let account = Account(name: "Separate", kind: .claudeCode)
    let snapshot = try await ClaudeUsageAdapter(executable: cli, root: root).fetch(account: account, now: checkTime)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.identity == "separate@example.com")
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(calls.count == 2)
    #expect(calls[0] == "auth status --json")
    #expect(calls[1] == "-p /usage --output-format json --safe-mode --no-session-persistence --tools  --strict-mcp-config --mcp-config {\"mcpServers\":{}}")
    #expect(FileManager.default.fileExists(atPath: Paths.claudeProfile(account.id, root: root).path))
}

@Test func claudeEmailOnlyComesFromSignedInSubscriptionIdentity() throws {
    let signedIn = try ClaudeAuthIdentity.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"  person@example.com  "}"#.utf8))
    #expect(signedIn.signedIn)
    #expect(signedIn.email == "person@example.com")
    for json in [
        #"{"loggedIn":false,"authMethod":"claude.ai","email":"old@example.com"}"#,
        #"{"loggedIn":true,"authMethod":"api_key","email":"other@example.com"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"  "}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai"}"#
    ] {
        #expect(try ClaudeAuthIdentity.parse(Data(json.utf8)).email == nil)
    }
}
