import Foundation
import Testing
@testable import UsageCore

private let grokNow = ISO8601DateFormatter().date(from: "2026-11-04T18:00:00Z")!
private let grokBilling = #"{"config":{"creditUsagePercent":29,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-30T23:11:29.090+00:00","end":"2026-11-06T23:11:29.090+00:00"},"isUnifiedBillingUser":true},"subscription_tier":"Old cached name"}"#
private func grokParse(_ text: String) throws -> Snapshot {
    try GrokUsageParser.parse(Data(text.utf8), at: grokNow, identity: "person@example.com · workspace")
}
@Test func grokSharedPoolFeedsMenuAndHistoryWithoutDuplicatingBotUsage() throws {
    let snapshot = try grokParse(grokBilling)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].remainingPercent == 71)
    #expect(snapshot.windows[0].durationMinutes == 10080)
    #expect(snapshot.primaryWeeklyWindow(for: .grokSubscription) == snapshot.windows.first)
    #expect(snapshot.applicableWindows(for: .grokSubscription).count == 1)
    #expect(snapshot.sessionWindow(for: .grokSubscription) == nil)
    #expect(AllowanceStatus.evaluate(snapshot: snapshot, kind: .grokSubscription, now: grokNow).remainingPercent == 71)
    #expect(snapshot.isStale(at: snapshot.windows[0].resetsAt!))
    #expect(!ConnectionKind.grokSubscription.isAPI)
    #expect(ConnectionKind.grokSubscription.provider != ConnectionKind.xai.provider)
}
@Test func grokDoesNotInferMissingUsageOrLegacyBotCoverage() {
    for text in ["{}", #"{"config":null}"#, grokBilling.replacingOccurrences(of: "\"creditUsagePercent\":29,", with: ""),
                 grokBilling.replacingOccurrences(of: "\"isUnifiedBillingUser\":true", with: "\"isUnifiedBillingUser\":false"),
                 grokBilling.replacingOccurrences(of: "\"isUnifiedBillingUser\":true", with: "\"other\":true"),
                 grokBilling.replacingOccurrences(of: "29,", with: "101,"),
                 grokBilling.replacingOccurrences(of: "29,", with: "-1,"),
                 grokBilling.replacingOccurrences(of: "WEEKLY", with: "UNKNOWN"),
                 grokBilling.replacingOccurrences(of: "2026-11-06", with: "2026-11-01"),
                 grokBilling.replacingOccurrences(of: "2026-10-30", with: "2026-11-05")] {
        #expect(throws: (any Error).self) { try grokParse(text) }
    }
    #expect(throws: UsageError.accountChanged("another")) {
        try GrokUsageParser.parse(Data(grokBilling.utf8), at: grokNow, identity: "first", expectedIdentity: "another")
    }
}
@Test func grokExplicitZeroAndMonthlyPeriodRemainValid() throws {
    #expect(try grokParse(grokBilling.replacingOccurrences(of: "29,", with: "0,")).windows[0].usedPercent == 0)
    let monthly = try grokParse(grokBilling.replacingOccurrences(of: "WEEKLY", with: "MONTHLY"))
    #expect(monthly.windows[0].label == "Shared monthly allowance")
}
@Test func grokIdentityBindsEmailAndWorkspaceWithoutReadingTokens() throws {
    let info = #"{"methodId":"cached_token","email":"Person@example.com","principalType":"User","teamId":"11111111-1111-1111-1111-111111111111"}"#
    let identity = try GrokUsageParser.identity(Data(info.utf8))
    #expect(identity == "person@example.com · 11111111-1111-1111-1111-111111111111")
    #expect(try GrokUsageParser.identity(Data(info.replacingOccurrences(of: "11111111-1111-1111-1111-111111111111", with: "22222222-2222-2222-2222-222222222222").utf8)) != identity)
    for invalid in [info.replacingOccurrences(of: "cached_token", with: "api-key"), info.replacingOccurrences(of: "User", with: "Service"), info.replacingOccurrences(of: "Person@example.com", with: ""), "{}"] {
        #expect(throws: UsageError.authentication) { try GrokUsageParser.identity(Data(invalid.utf8)) }
    }
}
@Test func grokFramingHandlesSplitAndBatchedRepliesAndBoundsMemory() throws {
    var decoder = GrokLineDecoder()
    try decoder.append(Data("{\"id\":".utf8)); #expect(try decoder.next() == nil)
    try decoder.append(Data("1}\n{\"id\":2}\n".utf8))
    #expect(try decoder.next() == Data("{\"id\":1}".utf8))
    #expect(try decoder.next() == Data("{\"id\":2}".utf8))
    #expect(try decoder.next() == nil)
    #expect(throws: UsageError.invalidData) { try decoder.append(Data(repeating: 65, count: 2_016_385)) }
}

private func grokFixture(_ directory: URL, mode: String) throws -> URL {
    let file = directory.appendingPathComponent("grok-fixture")
    let script = """
    #!/usr/bin/python3
    import json, sys, os, time
    mode = '\(mode)'
    count = 0
    expected = ['initialize', '_x.ai/auth/info', '_x.ai/billing', '_x.ai/auth/info']
    for line in sys.stdin:
        request = json.loads(line)
        assert request['method'] == expected[count]
        assert 'XAI_API_KEY' not in os.environ
        assert sys.argv[1:] == ['agent', '--no-leader', 'stdio']
        count += 1
        if mode == 'timeout':
            time.sleep(10)
        if mode == 'reverse':
            print(json.dumps({'jsonrpc':'2.0','id':900,'method':'session/request_permission','params':{}}), flush=True)
            continue
        if mode == 'auth' and count == 3:
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32000,'message':'Authentication required'}}), flush=True)
            continue
        if count == 1:
            result = {'protocolVersion':1}
        elif count == 3:
            result = json.loads('\(grokBilling)')
        else:
            result = {'methodId':'cached_token','email':'person@example.com','principalType':'User','teamId':'11111111-1111-1111-1111-111111111111'}
            if mode == 'switch' and count == 4:
                result['teamId'] = '22222222-2222-2222-2222-222222222222'
        print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}), flush=True)
    """
    try Paths.writePrivate(Data(script.utf8), to: file, executable: true)
    return file
}
@Test func grokTransportReadsOnlyBillingAndRejectsAccountSwitchAndInteraction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for mode in ["success", "switch", "reverse", "auth", "timeout"] {
        let executable = try grokFixture(root, mode: mode)
        let adapter = GrokAdapter(executable: executable, timeout: mode == "timeout" ? 0.3 : 5)
        do {
            let value = try await adapter.fetch(account: Account(name: "Grok", kind: .grokSubscription), now: grokNow)
            #expect(mode == "success")
            #expect(value.windows.first?.usedPercent == 29)
        } catch {
            #expect(mode != "success")
            if mode == "auth" { #expect(error as? UsageError == .authentication) }
            if mode == "timeout" { #expect(error as? UsageError == .timeout) }
            if mode == "switch" {
                #expect(error as? UsageError == .accountChanged("person@example.com · 11111111-1111-1111-1111-111111111111"))
            }
        }
    }
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["AILLOWANCE_LIVE_GROK_TEST"] == "1"))
func grokLiveReadOnlySmoke() async throws {
    let executable = try #require(GrokAdapter.findExecutable())
    let snapshot = try await GrokAdapter(executable: executable).fetch(account: Account(name: "Grok", kind: .grokSubscription), now: Date())
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.identity != nil)
    print("Live Grok: \(snapshot.windows[0].usedPercent)% used; reset \(String(describing: snapshot.windows[0].resetsAt))")
}
