import Foundation
import Testing
@testable import UsageCore

private func json(_ string: String) -> Data { Data(string.utf8) }
private let referenceTime = Date(timeIntervalSince1970: 1_790_000_000)

@Test func codexPrefersMultipleBucketsAndPreservesUnits() throws {
    let report = json(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1790003600},"secondary":{"usedPercent":40,"windowDurationMins":10080}},"review":{"primary":{"usedPercent":15,"windowDurationMins":60}}}}"#)
    let result = try UsageParser.codex(report, at: referenceTime)
    #expect(result.windows.count == 3)
    #expect(result.windows[0].remainingPercent == 75)
    #expect(result.windows[0].label == "codex · 5h")
    #expect(result.windows[1].label == "codex · 7d")
    #expect(result.windows[0].resetsAt == referenceTime.addingTimeInterval(3600))
}

@Test func codexMissingIsNotZeroAndRestrictionsSurvive() throws {
    let result = try UsageParser.codex(json(#"{"rateLimits":{"primary":null,"secondary":null}}"#))
    #expect(result.windows.isEmpty)
    #expect(result.note?.contains("does not mean zero") == true)
    let blocked = try UsageParser.codex(json(#"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":0}}}"#))
    #expect(blocked.note?.contains("restriction") == true)
    #expect(throws: UsageError.invalidData) { try UsageParser.codex(json(#"{"rateLimits":{"primary":{"usedPercent":110}}}"#)) }
}

@Test func claudeIgnoresContextAndEstimatedSessionCost() throws {
    let absent = try UsageParser.claude(json(#"{"context_window":{"used_percentage":81},"cost":{"total_cost_usd":3.4}}"#))
    #expect(absent.windows.isEmpty)
    #expect(absent.costUSD == nil)
    let result = try UsageParser.claude(json(#"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1790003600},"seven_day":{"used_percentage":62.5}},"transcript_path":"PRIVATE","session_id":"SECRET"}"#), at: referenceTime)
    #expect(result.windows.count == 2)
    #expect(result.windows[0].remainingPercent == 100)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!encoded.contains("PRIVATE")); #expect(!encoded.contains("SECRET"))
}

@Test func staleAfterAgeOrResetNeverAssumesQuotaRecovered() throws {
    let window = try QuotaWindow(id: "x", label: "x", usedPercent: 99, resetsAt: referenceTime.addingTimeInterval(100))
    let snapshot = Snapshot(observedAt: referenceTime, windows: [window], source: "test")
    #expect(!snapshot.isStale(at: referenceTime.addingTimeInterval(99)))
    #expect(snapshot.isStale(at: referenceTime.addingTimeInterval(100)))
    #expect(snapshot.windows[0].usedPercent == 99)
    #expect(Snapshot(observedAt: referenceTime, source: "test").isStale(at: referenceTime.addingTimeInterval(901)))
}

@Test func monetaryUnitsAreProviderSpecificAndPrecise() throws {
    let claude = try UsageParser.costs(json(#"{"data":[{"results":[{"amount":"123.78912","currency":"USD"}]}],"has_more":false}"#), kind: .claudeAPI)
    #expect(claude.amount == Decimal(string: "1.2378912"))
    let openai = try UsageParser.costs(json(#"{"data":[{"results":[{"amount":{"value":0.06,"currency":"usd"}},{"amount":{"value":0.04,"currency":"usd"}}]}],"has_more":false}"#), kind: .openAIAPI)
    #expect(openai.amount == Decimal(string: "0.10"))
    #expect(throws: (any Error).self) { try UsageParser.costs(json(#"{"data":[{"results":[{"amount":{"currency":"usd"}}]}],"has_more":false}"#), kind: .openAIAPI) }
    #expect(throws: UsageError.invalidData) { try UsageParser.costs(json(#"{"data":[],"has_more":true}"#), kind: .openAIAPI) }
    #expect(throws: UsageError.invalidData) { try UsageParser.costs(json(#"{"data":[{"results":[{"amount":"12junk","currency":"USD"}]}],"has_more":false}"#), kind: .claudeAPI) }
    #expect(throws: UsageError.invalidData) { try UsageParser.costs(json(#"{"data":[{"results":[{"amount":"12","currency":"EUR"}]}],"has_more":false}"#), kind: .claudeAPI) }
}

private actor MockHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let responses: [(Data, Int, [String: String])]
    init(_ responses: [(Data, Int, [String: String])]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count; requests.append(request)
        guard index < responses.count else { throw UsageError.invalidData }
        let response = responses[index]
        return (response.0, HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: response.2)!)
    }
}

@Test func costsFetchEveryPageWithEncodedCursorAndFixedInterval() async throws {
    let first = json(#"{"data":[{"results":[{"amount":{"value":1.2,"currency":"usd"}}]}],"has_more":true,"next_page":"a&b=secret"}"#)
    let second = json(#"{"data":[{"results":[{"amount":{"value":2.3,"currency":"usd"}}]}],"has_more":false}"#)
    let mock = MockHTTP([(first, 200, [:]), (second, 200, [:])])
    let adapter = CostAdapter(transport: mock, credential: { _ in "test-admin" })
    let result = try await adapter.fetch(account: Account(name: "Work", kind: .openAIAPI), now: referenceTime)
    #expect(result.costUSD == Decimal(string: "3.5"))
    let requests = await mock.requests
    #expect(requests.count == 2)
    let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "page" }?.value == "a&b=secret")
    #expect(query.first { $0.name == "end_time" }?.value == "1790000000")
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.openai.com" })
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-admin")
}

@Test func repeatedPaginationFailsInsteadOfShowingPartialSum() async throws {
    let data = json(#"{"data":[],"has_more":true,"next_page":"same"}"#)
    let mock = MockHTTP([(data, 200, [:]), (data, 200, [:])])
    await #expect(throws: UsageError.invalidData) {
        try await CostAdapter(transport: mock, credential: { _ in "test" }).fetch(account: Account(name: "x", kind: .openAIAPI), now: referenceTime)
    }
}

@Test func httpFailuresAreSafeAndBackoffRespectsProvider() async throws {
    let mock = MockHTTP([(json(#"{"error":"DO NOT DISPLAY SECRET"}"#), 429, ["Retry-After": "7200"])])
    await #expect(throws: UsageError.rateLimited(7200)) {
        try await CostAdapter(transport: mock, credential: { _ in "test" }).fetch(account: Account(name: "x", kind: .claudeAPI), now: referenceTime)
    }
    var state = PollState()
    state.failed(UsageError.rateLimited(7200), at: referenceTime)
    #expect(state.nextAttempt == referenceTime.addingTimeInterval(7200))
    state.succeeded(at: referenceTime)
    #expect(state.failures == 0)
    #expect(state.nextAttempt == referenceTime.addingTimeInterval(60))
}

@Test func keysNeverAppearInMetadataAndAccountsHaveIndependentIDs() throws {
    let first = Account(name: "Same", kind: .openAIAPI)
    let second = Account(name: "Same", kind: .openAIAPI)
    #expect(first.id != second.id)
    let data = try JSONEncoder().encode(first)
    let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(Set(fields.keys) == ["id", "name", "kind", "enabled", "usesExistingCodex", "usesExistingClaude"])
    #expect(Paths.feed(first.id) != Paths.feed(second.id))
    #expect(Paths.profile(first.id) != Paths.profile(second.id))
}

@Test func claudeFeedEnforcesAccountBoundaryAndMissingFileIsUnavailable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(); let url = Paths.feed(id, root: root)
    #expect(throws: (any Error).self) { try ClaudeFeed.read(url, accountID: id) }
    let snapshot = try UsageParser.claude(json(#"{"rate_limits":{"five_hour":{"used_percentage":34}}}"#))
    try Paths.write(ClaudeFeed(accountID: id, snapshot: snapshot), to: url)
    #expect(try ClaudeFeed.read(url, accountID: id) == snapshot)
    #expect(throws: UsageError.invalidData) { try ClaudeFeed.read(url, accountID: UUID()) }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test func codexHandshakeReadsOnlyAccountAndLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.prepare(root)
    let script = root.appendingPathComponent("fake-codex")
    let text = """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'account/read'*) echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test"}}}' ;;
        *'account/rateLimits/read'*) echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}' ;;
        *) exit 9 ;;
      esac
    done
    """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let account = Account(name: "Fixture", kind: .codex)
    try Paths.prepare(Paths.profile(account.id, root: root))
    let result = try await CodexAdapter(executable: script, root: root).fetch(account: account, now: referenceTime)
    #expect(result.windows.first?.remainingPercent == 80)
    #expect(result.identity == "fixture@example.test")
}

@Test func keychainRoundTripWhenExplicitlyEnabled() throws {
    // Opt-in integration test; always uses an isolated random service and dummy values.
    guard ProcessInfo.processInfo.environment["USAGEBAR_TEST_KEYCHAIN"] == "1" else { return }
    let store = KeychainStore(service: "com.usagebar.test.\(UUID().uuidString)")
    let first = UUID(); let second = UUID()
    defer { try? store.delete(first); try? store.delete(second) }
    try store.save("dummy-one", for: first); try store.save("dummy-two", for: second)
    #expect(try store.read(first) == "dummy-one")
    try store.save("dummy-updated", for: first)
    #expect(try store.read(first) == "dummy-updated")
    #expect(try store.read(second) == "dummy-two")
    try store.delete(first)
    #expect(throws: UsageError.missingCredential) { try store.read(first) }
}

@Test func codexHungChildTimesOutAndIsTerminated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.prepare(root)
    let script = root.appendingPathComponent("hung-codex")
    try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let rpc = try CodexRPC(executable: script, home: root, existing: false, timeout: 0.1)
    let start = Date()
    #expect(throws: UsageError.timeout) { try rpc.initialize() }
    rpc.stop()
    rpc.process.waitUntilExit()
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(!rpc.process.isRunning)
}

@Test func errorStatusAndRetryDateDoNotLeakBody() async throws {
    for (status, expected) in [(401, UsageError.authentication), (403, .forbidden), (503, .server), (302, .invalidData)] {
        let mock = MockHTTP([(json("sensitive provider response"), status, [:])])
        await #expect(throws: expected) {
            try await CostAdapter(transport: mock, credential: { _ in "test" }).fetch(account: Account(name: "Test", kind: .openAIAPI), now: referenceTime)
        }
    }
    let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    let response = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 429, httpVersion: nil,
        headerFields: ["Retry-After": date.string(from: referenceTime.addingTimeInterval(900))])!
    #expect(CostAdapter.retryDelay(response, now: referenceTime) == 900)
}

@Test func oneMinuteRefreshKeepsManualMinimumAndProviderBackoff() {
    var state = PollState()
    #expect(state.shouldRefresh(at: referenceTime))
    state.succeeded(at: referenceTime)
    #expect(!state.shouldRefresh(at: referenceTime.addingTimeInterval(59)))
    #expect(state.shouldRefresh(at: referenceTime.addingTimeInterval(60)))
    #expect(!state.shouldRefresh(at: referenceTime.addingTimeInterval(29), manual: true))
    #expect(state.shouldRefresh(at: referenceTime.addingTimeInterval(30), manual: true))
    state.failed(UsageError.rateLimited(7200), at: referenceTime)
    #expect(!state.shouldRefresh(at: referenceTime.addingTimeInterval(60), manual: true))
    #expect(!state.shouldRefresh(at: referenceTime.addingTimeInterval(7199), manual: true))
    #expect(state.shouldRefresh(at: referenceTime.addingTimeInterval(7200)))
}
