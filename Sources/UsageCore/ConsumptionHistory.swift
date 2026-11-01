import Foundation

public struct MeasuredUsage: Codable, Equatable, Sendable {
    public var amount: Double = 0
    public var seconds: Double = 0
    public init(amount: Double = 0, seconds: Double = 0) { self.amount = amount; self.seconds = seconds }
}

public struct UsageDay: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var weekly: MeasuredUsage?
    public var session: MeasuredUsage?
    public var money: MeasuredUsage?
    public init(day: Date, weekly: MeasuredUsage? = nil, session: MeasuredUsage? = nil, money: MeasuredUsage? = nil) {
        self.day = day; self.weekly = weekly; self.session = session; self.money = money
    }
}

public struct ConsumptionBucket: Identifiable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    public var amount: Double
    public var coveredSeconds: Double
    public var partial: Bool
    public var segment: Int
    public var trend: Double
    public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

/// Deltas from continuous, same-window observations only. Refills, resets and gaps add no usage.
public enum ConsumptionHistory {
    private static func weeklyID(_ id: String?) -> Bool {
        let id = id?.lowercased() ?? ""
        return id.contains("week") || id.contains("secondary") || id == "7-day"
    }
    private static func sameReset(_ a: Date?, _ b: Date?) -> Bool {
        switch (a,b) {
        case (.none,.none): return true
        case let (.some(a),.some(b)): return abs(a.timeIntervalSince(b)) <= 120
        default: return false
        }
    }
    public static func append(_ existing: [UsageDay], previous: UsageHistoryPoint?, current: UsageHistoryPoint, kind: ConnectionKind) -> [UsageDay] {
        var days = Dictionary(uniqueKeysWithValues: existing.map { ($0.day, $0) })
        if let previous {
            let duration = current.timestamp.timeIntervalSince(previous.timestamp)
            let limit = max(previous.continuityInterval ?? 1800, current.continuityInterval ?? 1800)
            if duration > 0 && duration <= limit {
                var weekly: Double?, session: Double?, money: Double?
                if !kind.isAPI {
                    if weeklyID(previous.windowID), previous.windowID == current.windowID,
                       sameReset(previous.resetsAt, current.resetsAt),
                       let a = previous.remainingPercent, let b = current.remainingPercent, a >= b { weekly = a-b }
                    if sameReset(previous.sessionResetsAt, current.sessionResetsAt),
                       let a = previous.sessionRemainingPercent, let b = current.sessionRemainingPercent, a >= b { session = a-b }
                } else if kind.isBalance {
                    if let a = previous.balanceUSD, let b = current.balanceUSD, a >= b { money = NSDecimalNumber(decimal: a-b).doubleValue }
                } else if HistoryTrends.calendar.isDate(previous.timestamp, equalTo: current.timestamp, toGranularity: .month),
                          let a = previous.costUSD, let b = current.costUSD, b >= a { money = NSDecimalNumber(decimal: b-a).doubleValue }
                var cursor = previous.timestamp
                while cursor < current.timestamp {
                    let day = HistoryTrends.calendar.startOfDay(for: cursor)
                    let end = min(day.addingTimeInterval(86400), current.timestamp)
                    let seconds = end.timeIntervalSince(cursor)
                    var record = days[day] ?? UsageDay(day: day)
                    func add(_ value: Double?, to prior: MeasuredUsage?) -> MeasuredUsage? {
                        guard let value else { return prior }
                        return MeasuredUsage(amount: (prior?.amount ?? 0) + value * seconds / duration, seconds: (prior?.seconds ?? 0) + seconds)
                    }
                    record.weekly = add(weekly, to: record.weekly)
                    record.session = add(session, to: record.session)
                    record.money = add(money, to: record.money)
                    if record.weekly != nil || record.session != nil || record.money != nil { days[day] = record }
                    cursor = end
                }
            }
        }
        let cutoff = HistoryTrends.calendar.startOfDay(for: current.timestamp).addingTimeInterval(-359 * 86400)
        return days.values.filter { $0.day >= cutoff && $0.day <= current.timestamp }.sorted { $0.day < $1.day }
    }
    public static func rebuild(_ points: [UsageHistoryPoint], kind: ConnectionKind) -> [UsageDay] {
        var days: [UsageDay] = []
        for (previous,current) in zip(points,points.dropFirst()) { days = append(days, previous: previous, current: current, kind: kind) }
        return days
    }
    public static func buckets(_ days: [UsageDay], kind: ConnectionKind, session: Bool, since: Date, now: Date, weekly: Bool) -> [ConsumptionBucket] {
        let span: Double = weekly ? 7 * 86400 : 86400
        var groups: [Int: MeasuredUsage] = [:]
        for day in days where day.day >= since && day.day <= now {
            guard let value = kind.isAPI ? day.money : session ? day.session : day.weekly else { continue }
            let index = Int(day.day.timeIntervalSince(since) / span)
            var sum = groups[index] ?? MeasuredUsage()
            sum.amount += value.amount; sum.seconds += value.seconds; groups[index] = sum
        }
        var result: [ConsumptionBucket] = []
        var lastIndex: Int?, segment = 0
        for index in groups.keys.sorted() {
            if let lastIndex, index != lastIndex + 1 { segment += 1 }
            let start = since.addingTimeInterval(Double(index) * span), end = start.addingTimeInterval(span)
            let sum = groups[index]!
            let expected = max(1, min(now,end).timeIntervalSince(start))
            result.append(ConsumptionBucket(start: start, end: min(end, HistoryTrends.calendar.startOfDay(for: now).addingTimeInterval(86400)), amount: sum.amount, coveredSeconds: sum.seconds,
                partial: sum.seconds < expected * 0.9 || end > now, segment: segment, trend: sum.amount))
            lastIndex = index
        }
        // A trailing three-period mean, never blending across missing buckets.
        for index in result.indices {
            let window = result[max(0,index-2)...index].filter { $0.segment == result[index].segment }
            result[index].trend = window.map(\.amount).reduce(0,+) / Double(window.count)
        }
        return result
    }
}
