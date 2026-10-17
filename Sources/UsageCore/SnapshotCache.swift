import Foundation

/// Match live identity validation even before a refresh is possible. Different
/// API keys may have different budgets, so only subscription bindings conflict.
func duplicateSubscriptionAccountIDs(in accounts: [Account], snapshots: [UUID: Snapshot] = [:]) -> Set<UUID> {
    var identities: [String: [UUID]] = [:]
    for account in accounts where !account.kind.isAPI {
        guard let identity = CodexIdentity.normalized(account.expectedIdentity) ?? CodexIdentity.normalized(snapshots[account.id]?.identity) else { continue }
        identities[account.kind.rawValue + "|" + identity, default: []].append(account.id)
    }
    return Set(identities.values.filter { $0.count > 1 }.flatMap { $0 })
}

public struct UsageHistoryPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let remainingPercent: Double?
    public let balanceUSD: Decimal?
    public let costUSD: Decimal?
    public init(timestamp: Date, remainingPercent: Double? = nil, balanceUSD: Decimal? = nil, costUSD: Decimal? = nil) {
        self.timestamp = timestamp; self.remainingPercent = remainingPercent; self.balanceUSD = balanceUSD; self.costUSD = costUSD
    }
}

/// Private, bounded readings, never credentials. Cached timestamps and reset dates are preserved.
public struct SnapshotCache: Sendable {
    public static let maximumPoints = 96
    private let directory: URL
    private struct Record: Codable {
        var accountID: UUID
        var kind: ConnectionKind
        var scopeID: String?
        var identity: String?
        var snapshot: Snapshot
        var history: [UsageHistoryPoint]
    }
    public init(root: URL = Paths.root) { directory = root.appendingPathComponent("Readings", isDirectory: true) }
    private func file(_ account: Account) -> URL { directory.appendingPathComponent("\(account.id.uuidString).json") }
    private func read(_ account: Account, now: Date) -> Record? {
        guard let data = try? Paths.readData(file(account), limit: 131_072),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              record.accountID == account.id, record.kind == account.kind, record.scopeID == account.scopeID,
              record.history.count <= Self.maximumPoints, record.snapshot.observedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(record.snapshot.observedAt) <= 7 * 86400,
              (try? record.snapshot.validated()) != nil else { return nil }
        let expected = CodexIdentity.normalized(account.expectedIdentity)
        let actual = CodexIdentity.normalized(record.snapshot.identity)
        guard record.identity == expected else { return nil }
        if !account.kind.isAPI || expected != nil { guard expected != nil, expected == actual else { return nil } }
        record.history.removeAll { now.timeIntervalSince($0.timestamp) > 7 * 86400 }
        let moneyLimit = Decimal(string: "1000000000000000")!
        guard record.history.allSatisfy({ point in
            point.timestamp <= record.snapshot.observedAt && point.timestamp >= now.addingTimeInterval(-7 * 86400)
                && point.remainingPercent.map { $0.isFinite && (0...100).contains($0) } != false
                && point.balanceUSD.map { !$0.isNaN && $0 >= -moneyLimit && $0 <= moneyLimit } != false
                && point.costUSD.map { !$0.isNaN && $0 >= 0 && $0 <= moneyLimit } != false
        }), zip(record.history, record.history.dropFirst()).allSatisfy({ $0.0.timestamp < $0.1.timestamp }) else { return nil }
        return record
    }
    public func load(accounts: [Account], now: Date = Date()) -> [UUID: Snapshot] {
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts)
        return accounts.prefix(1000).filter { !duplicates.contains($0.id) }.reduce(into: [:]) { result, account in
            if let record = read(account, now: now) { result[account.id] = record.snapshot }
        }
    }
    public func loadHistory(accounts: [Account], now: Date = Date()) -> [UUID: [UsageHistoryPoint]] {
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts)
        return accounts.prefix(1000).filter { !duplicates.contains($0.id) }.reduce(into: [:]) { result, account in
            if let record = read(account, now: now) { result[account.id] = record.history }
        }
    }
    @discardableResult public func save(_ snapshot: Snapshot, for account: Account) throws -> [UsageHistoryPoint] {
        _ = try snapshot.validated()
        let identity = CodexIdentity.normalized(account.expectedIdentity)
        if !account.kind.isAPI || identity != nil {
            guard identity != nil, identity == CodexIdentity.normalized(snapshot.identity) else { throw UsageError.authentication }
        }
        let existing = read(account, now: snapshot.observedAt)
        // A delayed reading within the accepted clock skew must not move the
        // saved value backwards or leave history newer than its snapshot.
        if let existing, existing.snapshot.observedAt > snapshot.observedAt { return existing.history }
        var history = existing?.history ?? []
        history.removeAll { snapshot.observedAt.timeIntervalSince($0.timestamp) > 7 * 86400 }
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: snapshot.observedAt)
        if ![.unavailable, .stale, .restricted].contains(status.state) {
            let point = UsageHistoryPoint(timestamp: snapshot.observedAt, remainingPercent: status.remainingPercent,
                                          balanceUSD: snapshot.balanceUSD, costUSD: snapshot.costUSD)
            // Preserve the sample timestamp. Replacing it every minute would move
            // the five-minute boundary forever and leave the chart with one point.
            if history.last.map({ point.timestamp.timeIntervalSince($0.timestamp) >= 300 }) ?? true { history.append(point) }
            history = Array(history.suffix(Self.maximumPoints))
        }
        try Paths.write(Record(accountID: account.id, kind: account.kind, scopeID: account.scopeID,
                               identity: identity, snapshot: snapshot, history: history), to: file(account))
        return history
    }
    public func remove(_ account: Account) throws {
        let url = file(account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
