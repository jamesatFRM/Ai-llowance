import Foundation
import Testing
@testable import UsageCore

@Test func heatmapAllocatesOnlyObservedConsumptionAcrossHourBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let hour = Date(timeIntervalSince1970: 360000)
    let points = [UsageHistoryPoint(timestamp: hour.addingTimeInterval(3300), remainingPercent: 80),
                  UsageHistoryPoint(timestamp: hour.addingTimeInterval(3900), remainingPercent: 70),
                  UsageHistoryPoint(timestamp: hour.addingTimeInterval(4200), remainingPercent: 70)]
    let buckets = UsageHeatmap.hours(points: points, kind: .codex, calendar: calendar)
    #expect(buckets[hour] == 5)
    #expect(buckets[hour.addingTimeInterval(3600)] == 5)
    #expect(buckets.count == 2)
}
@Test func heatmapDoesNotInventActivityAcrossGapsOrResetsOrAPIDollars() {
    let start = Date(timeIntervalSince1970: 360000)
    let points = [UsageHistoryPoint(timestamp: start, remainingPercent: 80),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(300), remainingPercent: 100),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(4000), remainingPercent: 40)]
    #expect(UsageHeatmap.hours(points: points, kind: .codex).isEmpty)
    #expect(UsageHeatmap.hours(points: points, kind: .openAIAPI).isEmpty)
}
@Test func heatmapDistinguishesMeasuredQuietFromMissingHistory() {
    let start = Date(timeIntervalSince1970: 360000)
    let points = [UsageHistoryPoint(timestamp: start, remainingPercent: 80),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(300), remainingPercent: 80)]
    let buckets = UsageHeatmap.hours(points: points, kind: .claudeCode)
    #expect(buckets.count == 1)
    #expect(buckets.values.first == 0)
}
