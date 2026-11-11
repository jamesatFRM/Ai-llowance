import Foundation
import Testing
@testable import UsageCore

private let comparisonNow = Date(timeIntervalSince1970: 1_800_000_000)
private func comparisonDays(current: Double = 8, prior: Double = 10, count: Int = 14, seconds: Double = 86400) -> [UsageDay] {
    let end = HistoryTrends.calendar.startOfDay(for: comparisonNow)
    return (1...count).map { index in UsageDay(day: end.addingTimeInterval(-Double(index) * 86400), weekly: .init(amount: index <= 7 ? current : prior, seconds: seconds)) }
}

@Test func weeklyComparisonUsesConsumedPointsAndExcludesTheIncompleteDay() {
    var days = comparisonDays()
    days.append(UsageDay(day: HistoryTrends.calendar.startOfDay(for: comparisonNow), weekly: .init(amount: 99, seconds: 10)))
    let result = UsageComparison(days: days, kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(result.currentAmount == 56 && result.previousAmount == 70)
    #expect(abs(result.changePercent! + 20) < 0.0001)
    #expect(result.summary == "20% less vs last week")
    #expect(result.pairedDays == 7 && !result.partial)
    #expect(result.days.count == 7)
}

@Test func gapsAndUnequalCoverageNeverTurnIntoZeroOrAFalseTrend() {
    let missing = UsageComparison(days: Array(comparisonDays().prefix(7)), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(missing.changePercent == nil && missing.summary == "More history needed")
    #expect(missing.days.allSatisfy { $0.previous == nil })
    var unequal = comparisonDays()
    for index in 0..<7 { unequal[index].weekly?.seconds = 600 }
    let result = UsageComparison(days: unequal, kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(result.changePercent == nil && result.summary == "Uneven history coverage")
    let partial = UsageComparison(days: comparisonDays(seconds: 36000), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(partial.partial && partial.summary == "20% less observed")
}

@Test func zeroBaselineAndRecordedZeroStayDistinctFromMissingHistory() {
    let zero = UsageComparison(days: comparisonDays(current: 0, prior: 0), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(zero.summary == "No change in usage" && zero.changePercent == nil)
    let started = UsageComparison(days: comparisonDays(current: 3, prior: 0), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(started.summary == "New usage observed" && started.changePercent == nil)
    let stopped = UsageComparison(days: comparisonDays(current: 0), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(stopped.changePercent == -100)
    let large = UsageComparison(days: comparisonDays(current: 10, prior: 0.01), kind: .claudeCode, period: .week, now: comparisonNow)
    #expect(large.summary == "Much more usage")
}

@Test(arguments: [UsageComparisonPeriod.month, .year])
func calendarComparisonsUseSevenMatchedDaysWithoutInventingAnOlderPeriod(period: UsageComparisonPeriod) throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2028-03-01T12:00:00Z"))
    let empty = UsageComparison(days: [], kind: .claudeCode, period: period, now: now)
    #expect(empty.days.count == 7 && Set(empty.days.map(\.previousDay)).count == 7)
    let earlier = HistoryTrends.calendar.date(byAdding: period == .month ? .month : .year, value: -1, to: HistoryTrends.calendar.startOfDay(for: now))!
    #expect(empty.days.last?.previousDay == earlier.addingTimeInterval(-86400))
    let records = empty.days.flatMap { [UsageDay(day: $0.day, weekly: .init(amount: 12, seconds: 86400)), UsageDay(day: $0.previousDay, weekly: .init(amount: 10, seconds: 86400))] }
    let complete = UsageComparison(days: records, kind: .claudeCode, period: period, now: now)
    #expect(abs(complete.changePercent! - 20) < 0.0001)
    #expect(SnapshotCache.retentionDays >= 374)
}

@Test func APIComparisonsUseDollarsAndDoNotMixSubscriptionWindows() {
    let records = comparisonDays().map { UsageDay(day: $0.day, weekly: .init(amount: 500, seconds: 86400), session: .init(amount: 800, seconds: 86400), money: .init(amount: 2, seconds: 86400)) }
    let result = UsageComparison(days: records, kind: .vercelGateway, period: .week, now: comparisonNow)
    #expect(result.currentAmount == 14 && result.previousAmount == 14)
    #expect(result.summary == "About the same" && result.detail.contains("USD"))
    let off = UsageComparison(days: records, kind: .vercelGateway, period: .off, now: comparisonNow)
    #expect(off.summary == "$12.00 observed · 7d")
}

@Test func theOffSummaryIncludesTodaysMeasuredUsageAndRejectsInvalidChartAmounts() {
    let today = HistoryTrends.calendar.startOfDay(for: comparisonNow)
    let records = [UsageDay(day: today, weekly: .init(amount: 4, seconds: 600)),
                   UsageDay(day: today.addingTimeInterval(-86400), weekly: .init(amount: .greatestFiniteMagnitude, seconds: 3600))]
    let result = UsageComparison(days: records, kind: .claudeCode, period: .off, now: comparisonNow)
    #expect(result.summary == "4 pts observed · 7d")
    #expect(result.days.allSatisfy { $0.current == nil && $0.previous == nil })
}

@Test func retainedDailySummariesCoverAYearAgoPlusTheComparisonWeek() {
    let today = HistoryTrends.calendar.startOfDay(for: comparisonNow)
    let days = (0..<410).map { UsageDay(day: today.addingTimeInterval(-Double($0) * 86400), weekly: .init(amount: 2, seconds: 86400)) }
    let point = UsageHistoryPoint(timestamp: comparisonNow)
    let retained = ConsumptionHistory.append(days, previous: nil, current: point, kind: .claudeCode)
    #expect(retained.count == 400)
    let result = UsageComparison(days: retained, kind: .claudeCode, period: .year, now: comparisonNow)
    #expect(result.pairedDays == 7 && result.summary == "About the same")
}

@Test func accountChartPreferencesMigrateIndependentlyAndIgnoreUnknownFutureStyles() throws {
    var first = Account(name: "First", kind: .claudeCode)
    let second = Account(name: "Second", kind: .claudeCode)
    first.dashboardChartStyle = .glow; first.dashboardComparison = .week; first.dashboardCollapsed = true
    let saved = try JSONEncoder().encode([first, second])
    #expect(try JSONDecoder().decode([Account].self, from: saved) == [first, second])
    var json = try #require(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
    json[0]["dashboardChartStyle"] = "future-chart"; json[0]["dashboardComparison"] = "future-range"
    let restored = try JSONDecoder().decode([Account].self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored[0].dashboardChartStyle == nil && restored[0].dashboardComparison == nil)
    #expect(restored[0].dashboardCollapsed == true && restored[1].dashboardCollapsed == nil)
}

@Test func collapsedTilesCloseGapsAndWideSummariesKeepBalancedFrames() {
    let full = DashboardGridPlan(width: 1056, columns: 4, items: Array(repeating: DashboardGridItem(heights: [400]), count: 4) + [DashboardGridItem(heights: [180, 180]), DashboardGridItem(heights: [180, 180])])
    #expect(full.frames.suffix(2).allSatisfy { $0.span == 2 })
    let slightlyShorter = DashboardGridPlan(width: 1056, columns: 4, items: [400, 400, 400, 390].map { DashboardGridItem(heights: [Double($0)]) } + [DashboardGridItem(heights: [180, 180]), DashboardGridItem(heights: [180, 180])])
    #expect(slightlyShorter.frames.suffix(2).allSatisfy { $0.span == 2 })
    let folded = DashboardGridPlan(width: 1056, columns: 4, items: [DashboardGridItem(heights: [70])] + Array(repeating: DashboardGridItem(heights: [400]), count: 3) + [DashboardGridItem(heights: [160, 160]), DashboardGridItem(heights: [150, 150])])
    #expect(folded.frames[4].x == 0 && folded.frames[4].y == 82 && folded.frames[4].span == 1)
    #expect(folded.height < full.height)
}

@Test func dashboardGeometryFitsOneThroughTenAccountsWithoutOverlappingAtAnySupportedWidth() {
    for width in [736.0, 1056, 1416] {
        for count in 1...10 {
            let columns = DashboardGridPlan.columns(width: width, accounts: count)
            let heights = (0..<count).map { DashboardGridItem(heights: [$0 % 3 == 0 ? 70 : 400]) }
            let plan = DashboardGridPlan(width: width, columns: columns, items: heights + [DashboardGridItem(heights: [180, 170]), DashboardGridItem(heights: [160, 160])])
            #expect(columns <= 4)
            for (index, frame) in plan.frames.enumerated() {
                #expect(frame.x >= 0 && frame.x + frame.width <= width + 0.01)
                #expect(frame.y >= 0 && frame.y + frame.height <= plan.height + 0.01)
                for other in plan.frames.dropFirst(index + 1) {
                    #expect(frame.x + frame.width <= other.x + 0.01 || other.x + other.width <= frame.x + 0.01 || frame.y + frame.height <= other.y + 0.01 || other.y + other.height <= frame.y + 0.01)
                }
            }
        }
    }
}
