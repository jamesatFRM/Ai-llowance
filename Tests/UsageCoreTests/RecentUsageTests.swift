import Foundation
import Testing
@testable import UsageCore

@Test func recentUsageNeverMixesWeeklyAndFiveHourPointsIntoTheSameGraph() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func point(_ seconds: Double, weekly: Double?, session: Double) -> UsageHistoryPoint {
        var point = UsageHistoryPoint(timestamp: now.addingTimeInterval(seconds), remainingPercent: weekly ?? session,
            windowID: weekly == nil ? "codex.Primary" : "codex.Secondary", resetsAt: now.addingTimeInterval(weekly == nil ? 7200 : 86400))
        point.windowDurationMinutes = weekly == nil ? 300 : 10080
        point.sessionRemainingPercent = session; point.sessionResetsAt = now.addingTimeInterval(7200)
        return point
    }
    let points = [point(-1800, weekly: 90, session: 90), point(-900, weekly: 89, session: 70), point(0, weekly: nil, session: 30)]
    let mixed = RecentUsage.buckets(points, kind: .codex, now: now)
    #expect(mixed[22] == 1)
    #expect(mixed[23] == nil) // Missing weekly usage cannot become a 40-point session spike.
    let sessionOnly = RecentUsage.buckets([point(-900, weekly: nil, session: 70), point(0, weekly: nil, session: 30)], kind: .codex, now: now)
    #expect(sessionOnly[23] == 40)
}

@Test func recentUsageShowsConsumptionAndKeepsMissingBucketsEmpty() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func point(_ seconds: Double, _ remaining: Double) -> UsageHistoryPoint {
        var p = UsageHistoryPoint(timestamp: now.addingTimeInterval(seconds), remainingPercent: remaining, windowID: "week", resetsAt: now.addingTimeInterval(86400))
        p.windowDurationMinutes = 10080
        return p
    }
    let values = RecentUsage.buckets([point(-1800,80), point(-900,70), point(0,70)], kind: .claudeCode, now: now)
    #expect(values.count == 24)
    #expect(values.prefix(22).allSatisfy { $0 == nil })
    #expect(values[22] == 10 && values[23] == 0)
    let reset = RecentUsage.buckets([point(-900,10), point(0,100)], kind: .claudeCode, now: now)
    #expect(reset.allSatisfy { $0 == nil })
    let gap = RecentUsage.buckets([point(-7200,80), point(0,20)], kind: .claudeCode, now: now)
    #expect(gap.allSatisfy { $0 == nil })
}

@Test func recentUsageClipsIntervalsAndSupportsAPISpending() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let points = [UsageHistoryPoint(timestamp: now.addingTimeInterval(-22050), costUSD: 10),
                  UsageHistoryPoint(timestamp: now.addingTimeInterval(-21150), costUSD: 12)]
    let values = RecentUsage.buckets(points, kind: .openAIAPI, now: now)
    #expect(values[0] == 1)
    #expect(values.dropFirst().allSatisfy { $0 == nil })
}
