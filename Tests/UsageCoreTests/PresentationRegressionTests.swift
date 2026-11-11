import Foundation
import Testing
@testable import UsageCore

@Test func aPrimaryFiveHourLimitDoesNotClaimTheFiveHourReadingIsMissing() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = try QuotaWindow(id: "codex.Primary", label: "Session", usedPercent: 12,
        resetsAt: now.addingTimeInterval(7200), durationMinutes: 300)
    let snapshot = Snapshot(observedAt: now, windows: [session], source: "Fixture")
    let reading = ReadingPresentation(snapshot: snapshot, kind: .codex, now: now)
    #expect(reading.value == "88% left" && reading.title == "5-hour allowance")
    #expect(reading.session == nil && reading.secondaryLimitNote == "Weekly limit not reported")
    let week = try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 12, durationMinutes: 10080)
    let weekly = ReadingPresentation(snapshot: Snapshot(observedAt: now, windows: [week], source: "Fixture"), kind: .claudeCode, now: now)
    #expect(weekly.secondaryLimitNote == "5-hour limit not reported")
    #expect(ReadingPresentation(snapshot: nil, kind: .codex, now: now).secondaryLimitNote == "Awaiting limit details")
}

@Test func fractionalAllowanceLabelsMatchTheHeadlineAndAlwaysAddToOneHundred() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for percent in [0.0, 0.8, 34.6, 72.8, 99.9, 100] {
        let chart = try #require(AllowanceComposition(percent))
        let window = try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 100 - percent, durationMinutes: 10080)
        let snapshot = Snapshot(observedAt: now, windows: [window], source: "Fixture")
        let reading = ReadingPresentation(snapshot: snapshot, kind: .claudeCode, now: now)
        let menu = MenuEntry(provider: .claude, label: "Fixture", remainingPercent: window.remainingPercent, accountCount: 1)
        #expect(reading.value == "\(chart.remainingWholePercent)% left")
        #expect(MenuEntryPresentation.value(menu, preferences: MenuPreferences()) == "\(chart.remainingWholePercent)%")
        #expect(chart.remainingWholePercent + chart.usedWholePercent == 100)
        #expect(chart.remainingPercent == percent)
    }
    #expect(AllowanceComposition(.nan) == nil && AllowanceComposition(nil) == nil)
    #expect(AllowanceComposition(-1)?.remainingWholePercent == 0)
    #expect(AllowanceComposition(101)?.remainingWholePercent == 100)
}

@Test func expandedDropdownHistoryExcludesOldAndFutureReadingsAndBoundsPlotWork() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let points = (-10000...1).map { offset in
        UsageHistoryPoint(timestamp: now.addingTimeInterval(Double(offset) * 60), remainingPercent: Double(abs(offset) % 100), windowID: "week.all models")
    }
    let plotted = HistorySeries.recentSamples(points, kind: .claudeCode, now: now)
    #expect(plotted.count <= 120)
    #expect(plotted.allSatisfy { $0.timestamp >= now.addingTimeInterval(-86400) && $0.timestamp <= now })
    #expect(plotted.last?.timestamp == now)
    #expect(HistorySeries.recentSamples([points[0]], kind: .claudeCode, now: now).isEmpty)
}
