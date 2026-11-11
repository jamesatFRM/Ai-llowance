import Foundation

public enum UsageComparisonPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, week, month, year
    public var id: String { rawValue }
    public var title: String { switch self { case .off: "Off"; case .week: "WoW"; case .month: "MoM"; case .year: "YoY" } }
    public var previousLabel: String { switch self { case .off, .week: "last week"; case .month: "last month"; case .year: "last year" } }
}

public struct ComparisonDay: Identifiable, Equatable, Sendable {
    public var id: Date { day }
    public let day: Date
    public let previousDay: Date
    public let current: MeasuredUsage?
    public let previous: MeasuredUsage?
}

/// Compare seven completed UTC days with a calendar-shifted seven-day period.
/// Only paired, observed days contribute to the comparison; never infer usage in gaps.
public struct UsageComparison: Equatable, Sendable {
    public let period: UsageComparisonPeriod
    public let days: [ComparisonDay]
    public let pairedDays: Int
    public let currentAmount: Double
    public let previousAmount: Double
    public let currentCoverage: Double
    public let previousCoverage: Double
    public let changePercent: Double?
    public let summary: String
    public let detail: String
    public let partial: Bool

    public init(days records: [UsageDay], kind: ConnectionKind, period: UsageComparisonPeriod, now: Date) {
        self.period = period
        let calendar = HistoryTrends.calendar
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: end)!
        let component: Calendar.Component = period == .month ? .month : period == .year ? .year : .day
        let previousEnd = calendar.date(byAdding: component, value: period == .week || period == .off ? -7 : -1, to: end)!
        let previousStart = calendar.date(byAdding: .day, value: -7, to: previousEnd)!
        var byDay: [Date: MeasuredUsage] = [:]
        for record in records {
            guard record.day <= end, let measured = kind.isAPI ? record.money : record.weekly,
                  measured.amount.isFinite, measured.amount >= 0, measured.amount <= 1e15,
                  measured.seconds.isFinite, measured.seconds > 0, measured.seconds <= 86401 else { continue }
            byDay[calendar.startOfDay(for: record.day)] = measured
        }
        days = (0..<7).map { index in
            let day = calendar.date(byAdding: .day, value: index, to: start)!
            let prior = calendar.date(byAdding: .day, value: index, to: previousStart)!
            return ComparisonDay(day: day, previousDay: prior, current: byDay[day], previous: byDay[prior])
        }
        let paired = days.filter { $0.current != nil && $0.previous != nil }
        pairedDays = paired.count
        currentAmount = paired.reduce(0) { $0 + $1.current!.amount }
        previousAmount = paired.reduce(0) { $0 + $1.previous!.amount }
        currentCoverage = paired.reduce(0) { $0 + $1.current!.seconds } / Double(max(1, paired.count) * 86400)
        previousCoverage = paired.reduce(0) { $0 + $1.previous!.seconds } / Double(max(1, paired.count) * 86400)
        partial = paired.count < 7 || min(currentCoverage, previousCoverage) < 0.9
        let coverageRatio = max(currentCoverage, previousCoverage) / max(0.0001, min(currentCoverage, previousCoverage))
        let comparable = paired.count >= 3 && min(currentCoverage, previousCoverage) >= 0.05 && coverageRatio <= 1.25
        changePercent = comparable && previousAmount > 0 ? (currentAmount / previousAmount - 1) * 100 : nil
        let recent = byDay.filter { $0.key >= end.addingTimeInterval(-6 * 86400) && $0.key <= end }.values
        let recorded = recent.reduce(0) { $0 + $1.amount }
        if period == .off {
            summary = recent.isEmpty ? "Usage history building" : kind.isAPI ? String(format: "$%.2f observed · 7d", recorded) : String(format: "%.0f pts observed · 7d", recorded)
        } else if paired.count < 3 {
            summary = "More history needed"
        } else if !comparable {
            summary = "Uneven history coverage"
        } else if let changePercent {
            if abs(changePercent) < 2 { summary = "About the same" }
            else if changePercent > 9999 { summary = "Much more usage" }
            else { summary = String(format: "%.0f%% %@%@", abs(changePercent), changePercent < 0 ? "less" : "more", partial ? " observed" : " vs " + period.previousLabel) }
        } else {
            summary = currentAmount > 0 ? "New usage observed" : "No change in usage"
        }
        detail = period == .off ? "Observed usage over the last seven UTC calendar days, including today. Gaps, refills and quota resets are excluded."
            : "Last 7 completed days (UTC) vs the same length ending one " + (period == .month ? "month" : period == .year ? "year" : "week")
            + " earlier. Compared \(paired.count) paired days; observed coverage "
            + String(format: "%.0f%% vs %.0f%%", currentCoverage * 100, previousCoverage * 100)
            + ". Gaps, refills and quota resets add no usage. "
            + (kind.isAPI ? "Amounts are observed USD consumption." : "Amounts are points of this account’s weekly allowance, not tokens.")
    }
}
