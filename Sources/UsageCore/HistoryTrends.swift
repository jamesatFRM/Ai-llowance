import Foundation

/// Actual daily closing readings; never interpolates missing days or adds quotas together.
public enum HistoryTrends {
    public static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    public static let ranges = [7, 14, 30, 60, 90, 180, 360]
    public static func daily(_ points: [UsageHistoryPoint], kind: ConnectionKind, session: Bool, since: Date, now: Date, calendar: Calendar = HistoryTrends.calendar) -> [HistorySample] {
        var days: [Date: HistorySample] = [:]
        for point in points where point.timestamp >= since && point.timestamp <= now {
            let value: Double?
            if kind.isBalance { value = point.balanceUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            else if kind.isAPI { value = point.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            else if session { value = point.sessionRemainingPercent }
            else {
                let id = point.windowID?.lowercased() ?? ""
                guard id.contains("week") || id.contains("secondary") || id == "7-day" else { continue }
                value = point.remainingPercent
            }
            guard let value, value.isFinite else { continue }
            let day = calendar.startOfDay(for: point.timestamp)
            if days[day].map({ $0.timestamp > point.timestamp }) == true { continue }
            days[day] = HistorySample(timestamp: point.timestamp, value: value, segment: 0)
        }
        return days.keys.sorted().compactMap { days[$0] }
    }
}
