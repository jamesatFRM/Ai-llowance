import Foundation
import Testing
@testable import UsageCore

private struct AccountRoutingTransport: HTTPTransport {
    let kind: ConnectionKind
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let credential = request.value(forHTTPHeaderField: kind == .claudeAPI ? "x-api-key" : "Authorization")
        let first = credential == (kind == .claudeAPI ? "fixture-one" : "Bearer fixture-one")
        #expect(first || credential == (kind == .claudeAPI ? "fixture-two" : "Bearer fixture-two"))
        let amount = first ? 12 : 34
        let payload: String
        switch kind {
        case .openAIAPI:
            #expect(request.url?.host == "api.openai.com")
            payload = "{\"data\":[{\"results\":[{\"amount\":{\"value\":\(amount),\"currency\":\"usd\"}}]}],\"has_more\":false}"
        case .claudeAPI:
            #expect(request.url?.host == "api.anthropic.com")
            payload = "{\"data\":[{\"results\":[{\"amount\":\"\(amount * 100)\",\"currency\":\"USD\"}]}],\"has_more\":false}"
        case .openRouter:
            #expect(request.url?.host == "openrouter.ai")
            payload = "{\"data\":{\"limit\":100,\"limit_remaining\":\(amount)}}"
        case .vercelGateway:
            #expect(request.url?.host == "ai-gateway.vercel.sh")
            payload = "{\"balance\":\(amount),\"total_used\":1}"
        case .xai:
            let team = first ? "team-one" : "team-two"
            #expect(request.url?.path == "/v1/billing/teams/\(team)/prepaid/balance")
            payload = "{\"total\":{\"val\":\"-\(amount * 100)\"},\"changes\":[{\"teamId\":\"\(team)\"}]}"
        default: throw UsageError.invalidData
        }
        return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test(arguments: [ConnectionKind.openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai])
func apiAccountsKeepTheirOwnCredentialAndScope(kind: ConnectionKind) async throws {
    let first = Account(name: "One", kind: kind, scopeID: kind == .xai ? "team-one" : nil)
    let second = Account(name: "Two", kind: kind, scopeID: kind == .xai ? "team-two" : nil)
    let credentials = [first.id: "fixture-one", second.id: "fixture-two"]
    let credential: @Sendable (UUID) throws -> String = { id in
        guard let value = credentials[id] else { throw UsageError.missingCredential }
        return value
    }
    let transport = AccountRoutingTransport(kind: kind)
    let adapter: any UsageAdapter = kind.isBalance
        ? BalanceAdapter(transport: transport, credential: credential)
        : CostAdapter(transport: transport, credential: credential)
    for account in [first, second, first] {
        let snapshot = try await adapter.fetch(account: account, now: Date())
        #expect((snapshot.balanceUSD ?? snapshot.costUSD) == Decimal(account.id == first.id ? 12 : 34))
        if kind == .xai { #expect(snapshot.identity == account.scopeID) }
    }
}

@Test(arguments: [ConnectionKind.openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai])
func replacedAPIKeyCannotRestorePreviousCredentialReadings(kind: ConnectionKind) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyRevision-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Account", kind: kind, scopeID: kind == .xai ? "team" : nil)
    let cache = SnapshotCache(root: root)
    let old = Snapshot(observedAt: Date(), costUSD: kind.isBalance ? nil : 12, source: "Fixture", balanceUSD: kind.isBalance ? 12 : nil)
    try cache.save(old, for: account)
    let previous = account
    account.credentialRevision = UUID()
    #expect(cache.load(accounts: [account]).isEmpty)
    #expect(cache.loadHistory(accounts: [account]).isEmpty)
    // Simulate a queued old-key cache write completing after key replacement.
    try cache.save(old, for: previous)
    #expect(cache.load(accounts: [account]).isEmpty)
    let fresh = Snapshot(observedAt: Date(), costUSD: kind.isBalance ? nil : 34, source: "Fixture", balanceUSD: kind.isBalance ? 34 : nil)
    try cache.save(fresh, for: account)
    #expect(cache.load(accounts: [account])[account.id] == fresh)
    #expect(cache.loadHistory(accounts: [account])[account.id]?.count == 1)
}
