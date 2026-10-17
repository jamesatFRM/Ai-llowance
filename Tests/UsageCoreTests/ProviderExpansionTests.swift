import Foundation
import Testing
@testable import UsageCore

private let providerNow = Date(timeIntervalSince1970: 1_800_000_000)
private func jsonData(_ text: String) -> Data { Data(text.utf8) }
private let finiteCopilot = #"{"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":300,"usedRequests":240,"remainingPercentage":20,"resetDate":"2027-02-01T00:00:00Z"},"chat":{"isUnlimitedEntitlement":true,"entitlementRequests":-1,"usedRequests":12,"remainingPercentage":100}}}"#

@Test func copilotUsesProviderRemainingAndPreservesSeparateEntitlements() throws {
    let result = try CopilotUsageParser.parse(jsonData(finiteCopilot), at: providerNow, identity: "octocat", expectedIdentity: "Octocat")
    #expect(result.windows.count == 1)
    #expect(result.windows.first?.remainingPercent == 20)
    #expect(result.windows.first?.resetsAt != nil)
    #expect(result.unlimited != true)
    #expect(result.identity == "octocat")
    #expect(throws: UsageError.accountChanged("other")) {
        try CopilotUsageParser.parse(jsonData(finiteCopilot), at: providerNow, identity: "octocat", expectedIdentity: "other")
    }
}

@Test func copilotUnlimitedIsNotAZeroPercentQuota() throws {
    let text = #"{"quotaSnapshots":{"chat":{"isUnlimitedEntitlement":true,"entitlementRequests":-1,"usedRequests":12,"remainingPercentage":100}}}"#
    let result = try CopilotUsageParser.parse(jsonData(text), at: providerNow, identity: "octocat")
    #expect(result.unlimited == true)
    #expect(result.windows.isEmpty)
}

@Test func copilotRejectsMissingMalformedAndContradictoryQuota() {
    for text in [#"{}"#, #"{"quotaSnapshots":{}}"#,
        finiteCopilot.replacingOccurrences(of: "\"remainingPercentage\":20", with: "\"remainingPercentage\":101"),
        finiteCopilot.replacingOccurrences(of: "\"usedRequests\":240", with: "\"usedRequests\":-1"),
        finiteCopilot.replacingOccurrences(of: "\"entitlementRequests\":300", with: "\"entitlementRequests\":-1"),
        finiteCopilot.replacingOccurrences(of: "\"entitlementRequests\":-1", with: "\"entitlementRequests\":300"),
        finiteCopilot.replacingOccurrences(of: "2027-02-01T00:00:00Z", with: "later") ] {
        #expect(throws: (any Error).self) { try CopilotUsageParser.parse(jsonData(text), at: providerNow, identity: "octocat") }
    }
}

@Test func copilotIdentityRequiresVerifiedLoginAndHost() throws {
    let source = #"{"isAuthenticated":true,"authType":"user","login":"Octocat","host":"https://github.com"}"#
    #expect(try CopilotUsageParser.identity(jsonData(source)) == "octocat")
    // Enterprise Managed Users have an underscore plus enterprise shortcode.
    let managed = source.replacingOccurrences(of: "Octocat", with: "Mona-cat_octo")
    #expect(try CopilotUsageParser.identity(jsonData(managed)) == "mona-cat_octo")
    #expect(try CopilotUsageParser.identity(jsonData(managed.replacingOccurrences(of: "github.com", with: "octo.ghe.com"))) == "octo.ghe.com/mona-cat_octo")
    for text in [source.replacingOccurrences(of: "true", with: "false"),
        source.replacingOccurrences(of: "https://github.com", with: "http://github.com"),
        source.replacingOccurrences(of: "https://github.com", with: "https://github.com.evil.example"),
        source.replacingOccurrences(of: "\"user\"", with: "\"api-key\""),
        source.replacingOccurrences(of: "Octocat", with: "") ] {
        #expect(throws: UsageError.authentication) { try CopilotUsageParser.identity(jsonData(text)) }
    }
}

@Test func copilotStdioFramingHandlesFragmentsAndRejectsOversizedResponses() throws {
    var decoder = CopilotFrameDecoder()
    try decoder.append(jsonData("Content-Length: 2\r\n\r\n{")); #expect(try decoder.next() == nil)
    try decoder.append(jsonData("}Content-Length: 2\r\n\r\n{}"))
    #expect(try decoder.next() == jsonData("{}")); #expect(try decoder.next() == jsonData("{}"))
    #expect(try decoder.next() == nil)
    for header in ["Content-Length: 2000001", "Content-Length: -1", "Content-Length: 2\r\nContent-Length: 2", "Size: 2"] {
        var invalid = CopilotFrameDecoder(); try invalid.append(jsonData(header + "\r\n\r\n{}"))
        #expect(throws: UsageError.invalidData) { try invalid.next() }
    }
}

@Test func openRouterReportsTightestProviderBudgetWithoutPretendingItIsCreditBalance() throws {
    let data = jsonData(#"{"data":{"limit":100,"limit_remaining":74.5,"effective_budget":{"limit_usd":50,"remaining_usd":17.5,"resets_at":"2027-02-01T00:00:00.000Z","scope":"member"}}}"#)
    let result = try BalanceParser.parse(data, kind: .openRouter, at: providerNow)
    #expect(result.balanceUSD == Decimal(string: "17.5"))
    #expect(result.balanceLabel == "Budget left")
    #expect(result.windows.count == 2)
    #expect(result.windows.first(where: { $0.id == "effective-budget" })?.remainingPercent == 35)
    #expect(result.costUSD == nil)
    #expect(result.note?.contains("Account credit balance") == true)
}

@Test func openRouterUnconfiguredBudgetIsNotUnlimitedAccountCredit() throws {
    let result = try BalanceParser.parse(jsonData(#"{"data":{"limit":null,"limit_remaining":null}}"#), kind: .openRouter, at: providerNow)
    #expect(result.balanceUSD == nil); #expect(result.unlimited != true); #expect(result.windows.isEmpty)
    let zero = try BalanceParser.parse(jsonData(#"{"data":{"limit":0,"limit_remaining":0}}"#), kind: .openRouter, at: providerNow)
    #expect(zero.balanceUSD == 0); #expect(zero.windows.first?.remainingPercent == 0)
}

@Test func openRouterStatusNeverClaimsToHaveAccountCredits() throws {
    for (data, title, state) in [
        (#"{"data":{"limit":100,"limit_remaining":100}}"#, "Budget remaining", AllowanceStatus.State.ready),
        (#"{"data":{"limit":100,"limit_remaining":0}}"#, "Budget exhausted", .exhausted),
        (#"{"data":{"limit":null,"limit_remaining":null}}"#, "No key budget", .unavailable)
    ] {
        let snapshot = try BalanceParser.parse(jsonData(data), kind: .openRouter, at: providerNow)
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: .openRouter, now: providerNow)
        #expect(status.title == title); #expect(status.state == state)
        #expect(!status.title.lowercased().contains("credit"))
    }
}

@Test func apiBalancesRejectMalformedMissingNegativeAndInconsistentValues() {
    for text in [#"{"data":{}}"#, #"{"data":{"limit":100}}"#,
        #"{"data":{"limit":null,"limit_remaining":10}}"#, #"{"data":{"limit":10,"limit_remaining":11}}"#,
        #"{"data":{"limit":10,"limit_remaining":-1}}"#, #"{"data":{"limit":"NaN","limit_remaining":0}}"#,
        #"{"data":{"limit":true,"limit_remaining":false}}"#] {
        #expect(throws: UsageError.invalidData) { try BalanceParser.parse(jsonData(text), kind: .openRouter, at: providerNow) }
    }
    for text in [#"{}"#, #"{"balance":"-1","total_used":"1"}"#, #"{"balance":"5 dollars","total_used":"1"}"#, #"{"balance":"NaN","total_used":"1"}"#] {
        #expect(throws: UsageError.invalidData) { try BalanceParser.parse(jsonData(text), kind: .vercelGateway, at: providerNow) }
    }
}

@Test func vercelBalanceIsUSDAndLifetimeUsedIsNotMislabelledMonthlySpend() throws {
    let result = try BalanceParser.parse(jsonData(#"{"balance":"95.50","total_used":"4.50"}"#), kind: .vercelGateway, at: providerNow)
    #expect(result.balanceUSD == Decimal(string: "95.50")); #expect(result.costUSD == nil)
    #expect(result.windows.isEmpty); #expect(result.balanceLabel == "Team credits")
}

@Test func xaiPrepaidLedgerPreservesDocumentedSignAndExactCents() throws {
    // Official billing examples: PURCHASE -1000 cents; a +500-cent top-up has
    // a -500-cent ledger entry. https://docs.x.ai/developers/rest-api-reference/management/billing
    for (ledger, credits) in [("-1000", "10"), ("-500", "5"), ("-1234", "12.34"), ("1234", "-12.34"), ("0", "0")] {
        let data = jsonData("{\"changes\":[{\"teamId\":\"fixture-team\"}],\"total\":{\"val\":\"\(ledger)\"}}")
        let result = try BalanceParser.parse(data, kind: .xai, at: providerNow, scopeID: "fixture-team")
        #expect(result.balanceUSD == Decimal(string: credits))
        #expect(result.identity == "fixture-team")
        #expect(result.balanceLabel == "Prepaid credits")
        #expect(result.costUSD == nil); #expect(result.windows.isEmpty)
    }
}

@Test func xaiRejectsMalformedLedgerAndWrongTeam() {
    for text in [#"{}"#, #"{"total":{"val":null}}"#, #"{"total":{"val":true}}"#,
        #"{"total":{"val":-1000}}"#, #"{"total":{"val":"-1.23"}}"#,
        #"{"total":{"val":"1e3"}}"#, #"{"total":{"val":"NaN"}}"#,
        #"{"total":{"val":"9223372036854775808"}}"#] {
        #expect(throws: UsageError.invalidData) {
            try BalanceParser.parse(jsonData(text), kind: .xai, at: providerNow, scopeID: "fixture-team")
        }
    }
    #expect(throws: UsageError.accountChanged("fixture-team")) {
        try BalanceParser.parse(jsonData(#"{"total":{"val":"-1000"},"changes":[{"teamId":"other-team"}]}"#),
            kind: .xai, at: providerNow, scopeID: "fixture-team")
    }
    for scope in ["", "../other", "team?query=other", "team%2fother", "team/name", "team name", "a\n"] {
        #expect(throws: (any Error).self) { try BalanceAdapter.request(kind: .xai, key: "fixture", scopeID: scope) }
    }
}

private struct XAITransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.absoluteString == "https://management-api.x.ai/v1/billing/teams/fixture-team/prepaid/balance")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-fixture")
        return (jsonData(#"{"total":{"val":"-1234"}}"#), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func xaiReadsOnlySelectedTeamAndChecksBindingBeforeCredentials() async throws {
    var account = Account(name: "xAI", kind: .xai); account.scopeID = "fixture-team"
    let adapter = BalanceAdapter(transport: XAITransport(), credential: { _ in "management-fixture" })
    let result = try await adapter.fetch(account: account, now: providerNow)
    #expect(result.balanceUSD == Decimal(string: "12.34")); #expect(result.identity == "fixture-team")
    account.expectedIdentity = "other-team"
    let failBeforeKey = BalanceAdapter(transport: XAITransport(), credential: { _ in
        Issue.record("A mismatched xAI team must not read a credential"); throw UsageError.missingCredential
    })
    await #expect(throws: UsageError.accountChanged("other-team")) { try await failBeforeKey.fetch(account: account, now: providerNow) }
}

private struct BalanceTransport: HTTPTransport {
    let status: Int
    let retry: String?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.host == "openrouter.ai")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: retry.map { ["Retry-After": $0] })!
        return (jsonData(#"{"data":{"limit":10,"limit_remaining":3}}"#), response)
    }
}

@Test func balanceRefreshIsOneBoundedReadAndHonorsRateLimit() async throws {
    let account = Account(name: "Fixture", kind: .openRouter)
    let adapter = BalanceAdapter(transport: BalanceTransport(status: 200, retry: nil), credential: { _ in "fixture" })
    #expect(try await adapter.fetch(account: account, now: providerNow).balanceUSD == 3)
    let limited = BalanceAdapter(transport: BalanceTransport(status: 429, retry: "600"), credential: { _ in "fixture" })
    await #expect(throws: UsageError.rateLimited(600)) { try await limited.fetch(account: account, now: providerNow) }
    let unauthenticated = BalanceAdapter(transport: BalanceTransport(status: 401, retry: nil), credential: { _ in "fixture" })
    await #expect(throws: UsageError.authentication) { try await unauthenticated.fetch(account: account, now: providerNow) }
}

@Test func newAPIProvidersCannotFallThroughToAnthropicCostEndpoint() {
    for kind in [ConnectionKind.openRouter, .vercelGateway, .xai] {
        #expect(throws: UsageError.invalidData) { try CostAdapter.request(kind: kind, key: "fixture", now: providerNow, page: nil) }
    }
    #expect(throws: (any Error).self) { try BalanceAdapter.request(kind: .xai, key: "fixture") }
    #expect(throws: UsageError.missingCredential) { try BalanceAdapter.request(kind: .openRouter, key: "header\nattack") }
}

private func fakeCopilot(_ mode: String) throws -> (root: URL, executable: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-quota-test-\(UUID().uuidString)")
    try Paths.prepare(root)
    let executable = root.appendingPathComponent("copilot")
    let script = #"""
    #!/usr/bin/python3
    import json, os, sys, time
    assert sys.argv[1:] == ["--headless", "--no-auto-update", "--stdio", "--log-level", "none"]
    assert not any(k in os.environ for k in ["GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN", "COPILOT_SDK_AUTH_TOKEN"])
    mode = "MODE"
    auth_reads = 0
    while True:
        header = sys.stdin.buffer.readline()
        if not header: break
        length = int(header.decode().split(":", 1)[1])
        assert sys.stdin.buffer.readline() == b"\r\n"
        request = json.loads(sys.stdin.buffer.read(length))
        method = request["method"]
        if method == "connect":
            if mode == "timeout": time.sleep(5)
            if mode == "reverse":
                reverse = json.dumps({"jsonrpc": "2.0", "id": "R" * 1000000, "method": "fixture.reverse"}).encode()
                sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(reverse)).encode() + reverse)
                sys.stdout.buffer.flush()
                # A client that echoes the ID blocks on stdin beyond its read deadline.
                time.sleep(4)
                sys.exit(0)
            result = {"protocolVersion": 4 if mode == "protocol" else 3}
        elif method == "auth.getStatus":
            auth_reads += 1
            result = {"isAuthenticated": True, "authType": "user", "host": "https://github.com", "login": "other" if mode == "switch" and auth_reads > 1 else "octocat"}
        elif method == "account.getQuota":
            result = {"quotaSnapshots": {"premium_interactions": {"isUnlimitedEntitlement": False, "entitlementRequests": 300, "usedRequests": 150, "remainingPercentage": 50}}}
        else:
            raise RuntimeError("Unexpected operation: " + method)
        payload = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
        sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(payload)).encode() + payload)
        sys.stdout.buffer.flush()
    """#.replacingOccurrences(of: "MODE", with: mode)
    try Paths.writePrivate(Data(script.utf8), to: executable, executable: true)
    return (root, executable)
}

@Test func copilotQuotaRoundTripUsesOnlyMetadataAndStopsChild() async throws {
    let fixture = try fakeCopilot("ok"); defer { try? FileManager.default.removeItem(at: fixture.root) }
    var account = Account(name: "Copilot", kind: .copilot); account.expectedIdentity = "octocat"
    let snapshot = try await CopilotAdapter(executable: fixture.executable, timeout: 3).fetch(account: account, now: providerNow)
    #expect(snapshot.identity == "octocat"); #expect(snapshot.windows.first?.remainingPercent == 50)
}

@Test func copilotRejectsIdentityChangingMidReadAndUnknownProtocols() async throws {
    for mode in ["switch", "protocol"] {
        let fixture = try fakeCopilot(mode); defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: (any Error).self) {
            try await CopilotAdapter(executable: fixture.executable, timeout: 3)
                .fetch(account: Account(name: "Copilot", kind: .copilot), now: providerNow)
        }
    }
}

@Test func copilotStalledQuotaReadTimesOutAndCancellationIsPrompt() async throws {
    let fixture = try fakeCopilot("timeout"); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let started = Date()
    await #expect(throws: UsageError.timeout) {
        try await CopilotAdapter(executable: fixture.executable, timeout: 0.2)
            .fetch(account: Account(name: "Copilot", kind: .copilot), now: providerNow)
    }
    let task = Task {
        try await CopilotAdapter(executable: fixture.executable, timeout: 20)
            .fetch(account: Account(name: "Copilot", kind: .copilot), now: providerNow)
    }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func copilotRejectsReverseRequestsWithoutAnUnboundedPipeWrite() async throws {
    let fixture = try fakeCopilot("reverse"); defer { try? FileManager.default.removeItem(at: fixture.root) }
    let started = Date()
    await #expect(throws: UsageError.unavailable("Copilot requested an unsupported interactive action while reading quota.")) {
        try await CopilotAdapter(executable: fixture.executable, timeout: 1)
            .fetch(account: Account(name: "Copilot", kind: .copilot), now: providerNow)
    }
    #expect(Date().timeIntervalSince(started) < 2)
}
