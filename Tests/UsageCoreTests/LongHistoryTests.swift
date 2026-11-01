import Foundation
import Testing
@testable import UsageCore

@Test func scheduledThirtyMinuteHistoryRemainsContinuousButOutagesDoNot() {
    let now = Date()
    var a = UsageHistoryPoint(timestamp: now, remainingPercent: 80, windowID: "week")
    a.continuityInterval = 2250
    var b = UsageHistoryPoint(timestamp: now.addingTimeInterval(1801), remainingPercent: 70, windowID: "week")
    b.continuityInterval = 2250
    #expect(HistorySeries.samples([a,b], kind: .claudeCode).map(\.segment) == [0,0])
    #expect(abs(UsageHeatmap.hours(points: [a,b], kind: .claudeCode).values.reduce(0,+) - 10) < 0.001)
    let c = UsageHistoryPoint(timestamp: now.addingTimeInterval(7200), remainingPercent: 50, windowID: "week")
    #expect(HistorySeries.samples([a,b,c], kind: .claudeCode).map(\.segment) == [0,0,1])
}

@Test func resetsPersistImmediatelyAndSessionsSurviveReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Fixture", kind: .claudeCode); account.expectedIdentity = "fixture@example.com"
    let date = Date()
    func reading(_ offset: Double, remaining: Double, reset: Date) throws -> Snapshot {
        Snapshot(observedAt: date.addingTimeInterval(offset), windows: [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 100-remaining, resetsAt: reset, durationMinutes: 10080), try QuotaWindow(id: "session", label: "Session", usedPercent: 20, resetsAt: date.addingTimeInterval(7200), durationMinutes: 300)], identity: "fixture@example.com", source: "Fixture")
    }
    let cache = SnapshotCache(root: root)
    try cache.save(reading(0, remaining: 5, reset: date.addingTimeInterval(30)), for: account)
    let history = try cache.save(reading(60, remaining: 100, reset: date.addingTimeInterval(604800)), for: account)
    #expect(history.count == 2)
    #expect(history.last?.remainingPercent == 100)
    #expect(cache.loadHistory(accounts: [account], now: date.addingTimeInterval(60))[account.id]?.last?.sessionRemainingPercent == 80)
    // Old history remains available even when its current reading has expired.
    #expect(cache.load(accounts: [account], now: date.addingTimeInterval(30 * 86400)).isEmpty)
    #expect(cache.loadHistory(accounts: [account], now: date.addingTimeInterval(30 * 86400))[account.id]?.count == 2)
}

@Test func yearHistoryIsBoundedAndPreservesDailyClosingReadings() {
    let now = Date(timeIntervalSince1970: 1800000000)
    var points: [UsageHistoryPoint] = []
    for day in (0...370).reversed() {
        for hour in [0.0, 1.0, 2.0] {
            points.append(UsageHistoryPoint(timestamp: now.addingTimeInterval(-Double(day)*86400 + hour*60), remainingPercent: hour + 50, windowID: "week"))
        }
    }
    let compact = SnapshotCache.compact(points, now: now)
    #expect(compact.count < 400)
    #expect(compact.allSatisfy { now.timeIntervalSince($0.timestamp) <= SnapshotCache.retention })
    #expect(SnapshotCache.compact(compact, now: now) == compact)
    let daily = HistoryTrends.daily(compact, kind: .claudeCode, session: false, since: now.addingTimeInterval(-30*86400), now: now)
    #expect(daily.count <= 31)
    #expect(daily.dropLast().allSatisfy { $0.value == 52 })
    #expect(HistoryTrends.daily(compact, kind: .claudeCode, session: true, since: now.addingTimeInterval(-30*86400), now: now).isEmpty)
}

@Test func legacyHistoryDecodesWithoutInventingSessionUsage() throws {
    let point = try JSONDecoder().decode(UsageHistoryPoint.self, from: Data(#"{"timestamp":100,"remainingPercent":70,"windowID":"week.all models"}"#.utf8))
    #expect(point.sessionRemainingPercent == nil)
    #expect(point.continuityInterval == nil)
}

@Test func oldHistorySurvivesSuccessfulRefreshAndSessionSelectionStaysSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Fixture", kind: .claudeCode); account.expectedIdentity = "fixture@example.com"
    let now = Date()
    func reading(_ date: Date) throws -> Snapshot {
        Snapshot(observedAt: date, windows: [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 25, resetsAt: date.addingTimeInterval(86400), durationMinutes: 10080), try QuotaWindow(id: "session", label: "Session", usedPercent: 10, resetsAt: date.addingTimeInterval(3600), durationMinutes: 300)], identity: "fixture@example.com", source: "Fixture")
    }
    let cache = SnapshotCache(root: root)
    for age in [359.0, 180, 90, 30, 7, 1, 0] { try cache.save(reading(now.addingTimeInterval(-age*86400)), for: account) }
    let history = try #require(SnapshotCache(root: root).loadHistory(accounts: [account], now: now)[account.id])
    #expect(history.count == 7)
    #expect(history.first?.timestamp == now.addingTimeInterval(-359*86400))
    for range in HistoryTrends.ranges {
        let since = now.addingTimeInterval(-Double(range)*86400)
        let weeks = HistoryTrends.daily(history, kind: .claudeCode, session: false, since: since, now: now)
        let sessions = HistoryTrends.daily(history, kind: .claudeCode, session: true, since: since, now: now)
        #expect(weeks.allSatisfy { $0.value == 75 })
        #expect(sessions.allSatisfy { $0.value == 90 })
    }
}
