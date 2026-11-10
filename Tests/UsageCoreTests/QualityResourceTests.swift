import Foundation
import Testing
@testable import UsageCore

/// Opt-in repeatable cache benchmark with fake data, never provider traffic.
@Test func populatedYearCacheBenchmarkWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["AIL_QUALITY_BENCHMARK"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityBenchmark-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(), today = HistoryTrends.calendar.startOfDay(for: now)
    struct Record: Encodable {
        let accountID: UUID
        let kind: ConnectionKind
        let identity: String
        let snapshot: Snapshot
        let history: [UsageHistoryPoint]
        let usageDays: [UsageDay]
    }
    var accounts: [Account] = []
    for index in 0..<10 {
        var account = Account(name: "Fixture", kind: .codex)
        account.expectedIdentity = "fixture\(index)@example.com"; accounts.append(account)
        let snapshot = Snapshot(observedAt: now, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 25, durationMinutes: 10080)], identity: account.expectedIdentity, source: "Fixture")
        let points = (0..<SnapshotCache.maximumPoints).map { index in
            UsageHistoryPoint(timestamp: now.addingTimeInterval(-Double(SnapshotCache.maximumPoints - 1 - index) * 140), remainingPercent: 75, windowID: "codex.week")
        }
        let days = (0..<366).reversed().map { index in
            UsageDay(day: today.addingTimeInterval(-Double(index) * 86400), weekly: .init(amount: 5, seconds: 3600))
        }
        try Paths.write(Record(accountID: account.id, kind: account.kind, identity: account.expectedIdentity!, snapshot: snapshot, history: points, usageDays: days),
            to: root.appendingPathComponent("Readings/\(account.id.uuidString).json"))
    }
    let cache = SnapshotCache(root: root)
    let clock = ContinuousClock(), start = clock.now
    let state = cache.loadState(accounts: accounts, now: now)
    let singleRead = start.duration(to: clock.now)
    let legacyStart = clock.now
    _ = cache.load(accounts: accounts, now: now)
    _ = cache.loadHistory(accounts: accounts, now: now)
    _ = cache.loadUsage(accounts: accounts, now: now)
    let repeatedRead = legacyStart.duration(to: clock.now)
    #expect(state.snapshots.count == 10 && state.history.count == 10 && state.usage.count == 10)
    #expect(state.history.values.allSatisfy { $0.count == SnapshotCache.maximumPoints })
    #expect(state.usage.values.allSatisfy { $0.count == 366 })
    print("Year-cache benchmark (10 accounts, 4096 points and 366 summaries each): single decode \(singleRead); three decodes \(repeatedRead). Local warm-cache observation, not a cross-device performance guarantee.")
}
