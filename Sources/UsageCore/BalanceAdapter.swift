import Foundation

/// Only provider-reported API budgets/balances. These are never subscription quotas.
public enum BalanceParser {
    private struct Money: Decodable {
        let value: Decimal
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
                      text.count <= 80, let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN else { throw UsageError.invalidData }
                value = number
            } else { value = try container.decode(Decimal.self) }
            guard !value.isNaN, value >= 0 else { throw UsageError.invalidData }
        }
    }
    private struct RouterResponse: Decodable { let data: RouterKey }
    private struct RouterKey: Decodable {
        let limit: Money?
        let limit_remaining: Money?
        let effective_budget: Budget?
        // A missing limit is not the same as an explicitly unlimited key.
        let hasLimitField: Bool
        enum CodingKeys: String, CodingKey { case limit, limit_remaining, effective_budget }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            hasLimitField = values.contains(.limit)
            limit = try values.decodeIfPresent(Money.self, forKey: .limit)
            limit_remaining = try values.decodeIfPresent(Money.self, forKey: .limit_remaining)
            effective_budget = try values.decodeIfPresent(Budget.self, forKey: .effective_budget)
        }
    }
    private struct Budget: Decodable {
        let limit_usd: Money
        let remaining_usd: Money
        let resets_at: String?
        let scope: String
    }
    private struct GatewayResponse: Decodable { let balance: Money; let total_used: Money }
    private struct XAICents: Decodable {
        let val: String
        var dollars: Decimal {
            get throws {
                // xAI's documented protobuf USD-cents value is a signed integer string.
                guard val.range(of: #"^-?[0-9]+\z"#, options: .regularExpression) != nil,
                      val.count <= 20, let cents = Int64(val) else { throw UsageError.invalidData }
                return -Decimal(cents) / 100
            }
        }
    }
    private struct XAIChange: Decodable { let teamId: String? }
    private struct XAIBalance: Decodable { let total: XAICents; let changes: [XAIChange]? }

    public static func parse(_ data: Data, kind: ConnectionKind, at now: Date, scopeID: String? = nil) throws -> Snapshot {
        guard data.count <= 2_000_000 else { throw UsageError.invalidData }
        do {
            switch kind {
            case .vercelGateway:
                let value = try JSONDecoder().decode(GatewayResponse.self, from: data)
                // total_used is lifetime expenditure, not this month's cost or the original balance.
                return Snapshot(observedAt: now, source: "Vercel AI Gateway credits",
                    note: "Team API credit balance. The key selects the team; this is not a Vercel subscription allowance.",
                    balanceUSD: value.balance.value, balanceLabel: "Team credits", freshnessInterval: 3600)
            case .openRouter:
                let key = try JSONDecoder().decode(RouterResponse.self, from: data).data
                var budgets: [(id: String, label: String, remaining: Decimal, limit: Decimal, reset: Date?)] = []
                if let limit = key.limit {
                    guard let remaining = key.limit_remaining, remaining.value <= limit.value else { throw UsageError.invalidData }
                    budgets.append(("key-budget", "Key budget", remaining.value, limit.value, nil))
                } else if key.limit_remaining != nil { throw UsageError.invalidData }
                if let budget = key.effective_budget {
                    guard ["key", "member", "workspace", "organization"].contains(budget.scope),
                          budget.remaining_usd.value <= budget.limit_usd.value else { throw UsageError.invalidData }
                    let reset = try parseReset(budget.resets_at)
                    budgets.append(("effective-budget", "\(budget.scope.capitalized) budget", budget.remaining_usd.value, budget.limit_usd.value, reset))
                }
                guard key.hasLimitField || !budgets.isEmpty else { throw UsageError.invalidData }
                guard let available = budgets.min(by: { $0.remaining < $1.remaining }) else {
                    return Snapshot(observedAt: now, source: "OpenRouter key budget",
                        note: "No key budget is configured. This endpoint does not report total account credits; usage is not unlimited.",
                        balanceLabel: "No key budget", freshnessInterval: 3600)
                }
                let windows = try budgets.map { budget in
                    let remaining = budget.limit == 0 ? 0 : NSDecimalNumber(decimal: budget.remaining / budget.limit * 100).doubleValue
                    return try QuotaWindow(id: budget.id, label: budget.label, usedPercent: max(0, min(100, 100 - remaining)), resetsAt: budget.reset)
                }
                return Snapshot(observedAt: now, windows: windows, source: "OpenRouter key budget",
                    note: "Remaining API spending budget available to this key. Account credit balance and free-model limits may also apply.",
                    balanceUSD: available.remaining, balanceLabel: "Budget left", freshnessInterval: 3600)
            case .xai:
                let team = try xaiTeamID(scopeID)
                let value = try JSONDecoder().decode(XAIBalance.self, from: data)
                if let changes = value.changes {
                    guard changes.allSatisfy({ $0.teamId == nil || $0.teamId == team }) else {
                        throw UsageError.accountChanged(team)
                    }
                }
                // Official billing examples: a +500-cent top-up becomes a -500-cent
                // PURCHASE ledger entry. Negate the ledger; do not abs() away debt.
                return Snapshot(observedAt: now, identity: team, source: "xAI prepaid balance",
                    note: "Beta: team API prepaid credits, not a Grok subscription. Compare the first reading with xAI billing; postpaid usage and limits are separate.",
                    balanceUSD: try value.total.dollars, balanceLabel: "Prepaid credits", freshnessInterval: 3600)
            default: throw UsageError.invalidData
            }
        } catch let error as UsageError { throw error }
        catch { throw UsageError.invalidData }
    }
    static func xaiTeamID(_ value: String?) throws -> String {
        guard let value, value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z"#, options: .regularExpression) != nil else {
            throw UsageError.unavailable("Enter the xAI team ID from Console settings to read its prepaid credits.")
        }
        return value
    }
    private static func parseReset(_ text: String?) throws -> Date? {
        guard let text else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = format.date(from: text)
        format.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? format.date(from: text) else { throw UsageError.invalidData }
        return date
    }
}

public struct BalanceAdapter: UsageAdapter {
    private let transport: any HTTPTransport
    private let credential: @Sendable (UUID) throws -> String
    public init(transport: any HTTPTransport = SecureHTTPTransport(), credential: @escaping @Sendable (UUID) throws -> String = { try KeychainStore().read($0) }) {
        self.transport = transport; self.credential = credential
    }
    public static func request(kind: ConnectionKind, key: String, scopeID: String? = nil) throws -> URLRequest {
        let address: String
        switch kind {
        case .openRouter: address = "https://openrouter.ai/api/v1/key"
        case .vercelGateway: address = "https://ai-gateway.vercel.sh/v1/credits"
        case .xai:
            let team = try BalanceParser.xaiTeamID(scopeID)
            let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            guard let encoded = team.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { throw UsageError.invalidData }
            address = "https://management-api.x.ai/v1/billing/teams/\(encoded)/prepaid/balance"
        default: throw UsageError.invalidData
        }
        guard !key.isEmpty, key.utf8.count <= 16_384, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw UsageError.missingCredential }
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "GET"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
    public func fetch(account: Account, now: Date) async throws -> Snapshot {
        guard account.kind == .openRouter || account.kind == .vercelGateway || account.kind == .xai else {
            throw UsageError.unavailable("This API provider is not available for balance monitoring yet.")
        }
        if account.kind == .xai {
            let team = try BalanceParser.xaiTeamID(account.scopeID)
            if let expected = account.expectedIdentity, expected != team { throw UsageError.accountChanged(expected) }
        }
        try Task.checkCancellation()
        let request = try Self.request(kind: account.kind, key: credential(account.id), scopeID: account.scopeID)
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200: return try BalanceParser.parse(data, kind: account.kind, at: now, scopeID: account.scopeID)
        case 401: throw UsageError.authentication
        case 403: throw UsageError.unavailable("This key cannot read its budget or credit balance. Check the key's provider and permissions.")
        case 429: throw UsageError.rateLimited(CostAdapter.retryDelay(response, now: now))
        case 500...599: throw UsageError.server
        default: throw UsageError.invalidData
        }
    }
}
