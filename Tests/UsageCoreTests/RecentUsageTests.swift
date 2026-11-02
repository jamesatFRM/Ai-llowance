import Foundation
import Testing
@testable import UsageCore

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
