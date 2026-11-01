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
    public let windowID: String?
    public let resetsAt: Date?
    public var sessionRemainingPercent: Double?
    public var sessionResetsAt: Date?
    public var continuityInterval: TimeInterval?
    public var windowDurationMinutes: Int?
    public init(timestamp: Date, remainingPercent: Double? = nil, balanceUSD: Decimal? = nil, costUSD: Decimal? = nil, windowID: String? = nil, resetsAt: Date? = nil) {
        self.timestamp = timestamp; self.remainingPercent = remainingPercent; self.balanceUSD = balanceUSD; self.costUSD = costUSD
        self.windowID = windowID; self.resetsAt = resetsAt
    }
}

/// Private, bounded readings, never credentials. Cached timestamps and reset dates are preserved.
public struct SnapshotCache: Sendable {
    public static let maximumPoints = 4096
    public static let retention: TimeInterval = 360 * 86400

    /// Keep recent detail, then one actual closing observation per UTC day.
    public static func compact(_ points: [UsageHistoryPoint], now: Date) -> [UsageHistoryPoint] {
        let valid = points.filter { $0.timestamp >= now.addingTimeInterval(-retention) && $0.timestamp <= now }
        var days: [Int: UsageHistoryPoint] = [:]
        var recent: [UsageHistoryPoint] = []
        for point in valid {
            if now.timeIntervalSince(point.timestamp) <= 7 * 86400 { recent.append(point) }
            else { days[Int(floor(point.timestamp.timeIntervalSince1970 / 86400))] = point }
        }
        let older = days.keys.sorted().compactMap { days[$0] }
        return older + recent.suffix(maximumPoints - older.count)
    }

    public static func shouldAppend(_ point: UsageHistoryPoint, after previous: UsageHistoryPoint?) -> Bool {
        guard let previous else { return true }
        let resetChanged = point.resetsAt != previous.resetsAt && abs((point.resetsAt ?? .distantPast).timeIntervalSince(previous.resetsAt ?? .distantPast)) > 120
        let sessionReset = point.sessionResetsAt != previous.sessionResetsAt && abs((point.sessionResetsAt ?? .distantPast).timeIntervalSince(previous.sessionResetsAt ?? .distantPast)) > 120
        return point.windowID != previous.windowID || resetChanged || sessionReset
            || (point.remainingPercent ?? 0) > (previous.remainingPercent ?? 100)
            || (point.sessionRemainingPercent ?? 0) > (previous.sessionRemainingPercent ?? 100)
            || point.timestamp.timeIntervalSince(previous.timestamp) >= 300
    }
    private let directory: URL
    private struct Record: Codable {
        var accountID: UUID
        var kind: ConnectionKind
        var scopeID: String?
        var credentialRevision: UUID?
        var identity: String?
        var claudeProfileIsolated: Bool?
        var snapshotUsable: Bool?
        var snapshot: Snapshot
        var history: [UsageHistoryPoint]
        var usageDays: [UsageDay]? = nil
    }
    public init(root: URL = Paths.root) { directory = root.appendingPathComponent("Readings", isDirectory: true) }
    private func file(_ account: Account) -> URL { directory.appendingPathComponent("\(account.id.uuidString).json") }
    private func read(_ account: Account, now: Date) -> Record? {
        guard let data = try? Paths.readData(file(account), limit: 2_097_152),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              record.accountID == account.id, record.kind == account.kind, record.scopeID == account.scopeID,
              record.credentialRevision == account.credentialRevision,
              record.history.count <= Self.maximumPoints, record.snapshot.observedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(record.snapshot.observedAt) <= Self.retention,
              (try? record.snapshot.validated()) != nil else { return nil }
        if account.kind == .claudeCode {
            guard account.usesExistingClaude != true, record.claudeProfileIsolated == true else { return nil }
        }
        let expected = CodexIdentity.normalized(account.expectedIdentity)
        let actual = CodexIdentity.normalized(record.snapshot.identity)
        guard record.identity == expected else { return nil }
        if !account.kind.isAPI || expected != nil { guard expected != nil, expected == actual else { return nil } }
        record.history.removeAll { now.timeIntervalSince($0.timestamp) > Self.retention }
        let moneyLimit = Decimal(string: "1000000000000000")!
        guard record.history.allSatisfy({ point in
            point.timestamp <= record.snapshot.observedAt && point.timestamp >= now.addingTimeInterval(-Self.retention)
                && point.sessionRemainingPercent.map { $0.isFinite && (0...100).contains($0) } != false
                && point.continuityInterval.map { $0.isFinite && (1800...4500).contains($0) } != false
                && point.remainingPercent.map { $0.isFinite && (0...100).contains($0) } != false
                && point.balanceUSD.map { !$0.isNaN && $0 >= -moneyLimit && $0 <= moneyLimit } != false
                && point.costUSD.map { !$0.isNaN && $0 >= 0 && $0 <= moneyLimit } != false
        }), zip(record.history, record.history.dropFirst()).allSatisfy({ $0.0.timestamp < $0.1.timestamp }) else { return nil }
        if let days = record.usageDays {
            guard days.count <= 361, Set(days.map(\.day)).count == days.count,
                  days.allSatisfy({ day in
                      day.day <= record.snapshot.observedAt && [day.weekly, day.session, day.money].compactMap { $0 }.allSatisfy {
                          $0.amount.isFinite && $0.amount >= 0 && $0.seconds.isFinite && (0...86401).contains($0.seconds)
                      }
                  }) else { return nil }
        }
        return record
    }
    public func load(accounts: [Account], now: Date = Date()) -> [UUID: Snapshot] {
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts)
        return accounts.prefix(1000).filter { !duplicates.contains($0.id) }.reduce(into: [:]) { result, account in
            if let record = read(account, now: now), record.snapshotUsable != false, now.timeIntervalSince(record.snapshot.observedAt) <= 7 * 86400 { result[account.id] = record.snapshot }
        }
    }
    public func loadHistory(accounts: [Account], now: Date = Date()) -> [UUID: [UsageHistoryPoint]] {
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts)
        return accounts.prefix(1000).filter { !duplicates.contains($0.id) }.reduce(into: [:]) { result, account in
            if let record = read(account, now: now) { result[account.id] = record.history }
        }
    }
    public func loadUsage(accounts: [Account], now: Date = Date()) -> [UUID: [UsageDay]] {
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts)
        return accounts.filter { !duplicates.contains($0.id) }.reduce(into: [:]) { result, account in
            if let record = read(account, now: now) {
                result[account.id] = (record.usageDays.flatMap { $0.isEmpty ? nil : $0 } ?? ConsumptionHistory.rebuild(record.history, kind: account.kind))
                    .filter { $0.day >= HistoryTrends.calendar.startOfDay(for: now).addingTimeInterval(-359 * 86400) }
            }
        }
    }
    @discardableResult public func save(_ snapshot: Snapshot, for account: Account, interval: TimeInterval = 1800) throws -> [UsageHistoryPoint] {
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
        var usageDays = existing?.usageDays.flatMap { $0.isEmpty ? nil : $0 } ?? ConsumptionHistory.rebuild(history, kind: account.kind)
        history.removeAll { snapshot.observedAt.timeIntervalSince($0.timestamp) > Self.retention }
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: snapshot.observedAt)
        if ![.unavailable, .stale, .restricted].contains(status.state) {
            var point = UsageHistoryPoint(timestamp: snapshot.observedAt, remainingPercent: snapshot.displayWindow(for: account.kind)?.remainingPercent,
                                          balanceUSD: snapshot.balanceUSD, costUSD: snapshot.costUSD,
                                          windowID: snapshot.displayWindow(for: account.kind)?.id,
                                          resetsAt: snapshot.displayWindow(for: account.kind)?.resetsAt)
            point.windowDurationMinutes = snapshot.displayWindow(for: account.kind)?.durationMinutes
            point.sessionRemainingPercent = snapshot.sessionWindow(for: account.kind)?.remainingPercent
            point.sessionResetsAt = snapshot.sessionWindow(for: account.kind)?.resetsAt
            point.continuityInterval = min(4500, max(1800, interval * 1.25))
            // Preserve the sample timestamp. Replacing it every minute would move
            // the five-minute boundary forever and leave the chart with one point.
            if Self.shouldAppend(point, after: history.last) {
                usageDays = ConsumptionHistory.append(usageDays, previous: history.last, current: point, kind: account.kind)
                // A quota-window change can arrive with the same provider timestamp.
                // Replace that instant rather than writing duplicate dates that read() rejects.
                if history.last?.timestamp == point.timestamp { history[history.count - 1] = point }
                else { history.append(point) }
            }
            history = Self.compact(history, now: snapshot.observedAt)
        }
        try Paths.write(Record(accountID: account.id, kind: account.kind, scopeID: account.scopeID, credentialRevision: account.credentialRevision,
                               identity: identity, claudeProfileIsolated: account.kind == .claudeCode ? account.usesExistingClaude != true : nil, snapshot: snapshot, history: history, usageDays: usageDays), to: file(account))
        return history
    }
    /// Reauthentication invalidates the current reading, not verified historical samples.
    public func invalidateSnapshot(_ account: Account, now: Date = Date()) throws {
        guard var record = read(account, now: now) else { return }
        record.snapshotUsable = false
        try Paths.write(record, to: file(account))
    }
    public func remove(_ account: Account) throws {
        let url = file(account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
