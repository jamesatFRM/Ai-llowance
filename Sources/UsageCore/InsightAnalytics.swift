import Foundation

public struct InsightInterval: Sendable {
    public let start: Date
    public let end: Date
    public let amount: Double
    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}
public struct InsightRateBucket: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
    public let amount: Double
    public let measuredSeconds: Double
    public let segment: Int
    public var ratePerHour: Double { amount / max(1, measuredSeconds) * 3600 }
    public var coverage: Double { min(1, measuredSeconds / max(1, end.timeIntervalSince(start))) }
    public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}
public struct InsightAllowancePoint: Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let remaining: Double
    public let segment: Int
}
public struct WeeklyPace: Sendable {
    public let cycleStart: Date
    public let resetAt: Date
    public let observedAt: Date
    public let remaining: Double
    public let measuredSeconds: Double
    public let points: [InsightAllowancePoint]
    public let pointsPerDay: Double?
    public let estimatedRemaining: Double?
    public let estimatedExhaustion: Date?
}
public struct InsightCalendarDay: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    /// Nil is an unmeasured day, distinct from a measured zero.
    public let amount: Double?
    public let measuredSeconds: Double
    public init(date: Date, amount: Double?, measuredSeconds: Double) { self.date = date; self.amount = amount; self.measuredSeconds = measuredSeconds }
}
public struct InsightCalendar: Sendable {
    public let days: [InsightCalendarDay]
    public var activeDays: Int { days.filter { ($0.amount ?? 0) > 0 }.count }
    public var measuredDays: Int { days.filter { $0.amount != nil }.count }
    public var busiestDay: InsightCalendarDay? { days.filter { $0.amount != nil }.max { $0.amount! < $1.amount! } }
    public var longestStreak: Int {
        var longest = 0, current = 0
        for day in days { current = (day.amount ?? 0) > 0 ? current + 1 : 0; longest = max(longest, current) }
        return longest
    }
}
public struct CreditRunway: Sendable {
    public let balance: Double
    public let observedSpending: Double
    public let measuredSeconds: Double
    public let measuredDays: Int
    public let estimatedDailySpending: Double?
    public let estimatedDaysLeft: Double?
}

/// Bounded, local calculations. Refills, resets and unmeasured gaps never become consumption.
public enum InsightAnalytics {
    private static func matchesReset(_ a: Date?, _ b: Date?) -> Bool {
        switch (a,b) {
        case (nil,nil): true
        case let (.some(a),.some(b)): abs(a.timeIntervalSince(b)) <= 120
        default: false
        }
    }
    private static func value(_ point: UsageHistoryPoint, kind: ConnectionKind, metric: InsightMetric) -> Double? {
        let value: Double?
        if kind.isAPI {
            value = (kind.isBalance ? point.balanceUSD : point.costUSD).map { NSDecimalNumber(decimal: $0).doubleValue }
        } else if metric == .session { value = point.sessionRemainingPercent }
        else { value = ResetCycles.isWeekly(point) ? point.remainingPercent : nil }
        return value.flatMap { $0.isFinite && $0 >= 0 && (kind.isAPI || $0 <= 100) ? $0 : nil }
    }
    public static func intervals(_ points: [UsageHistoryPoint], kind: ConnectionKind, metric: InsightMetric = .weekly, since: Date, now: Date) -> [InsightInterval] {
        let points = points.suffix(SnapshotCache.maximumPoints)
        var result: [InsightInterval] = []
        for (a,b) in zip(points, points.dropFirst()) {
            let duration = b.timestamp.timeIntervalSince(a.timestamp)
            guard b.timestamp > since, b.timestamp <= now, duration > 0,
                  duration <= max(a.continuityInterval ?? 1800, b.continuityInterval ?? 1800),
                  let first = value(a, kind: kind, metric: metric), let last = value(b, kind: kind, metric: metric) else { continue }
            let amount: Double
            if kind.isAPI {
                guard kind.isBalance || HistoryTrends.calendar.isDate(a.timestamp, equalTo: b.timestamp, toGranularity: .month) else { continue }
                amount = kind.isBalance ? first - last : last - first
            } else {
                guard metric == .session ? matchesReset(a.sessionResetsAt, b.sessionResetsAt)
                    : a.windowID == b.windowID && matchesReset(a.resetsAt,b.resetsAt) else { continue }
                amount = first - last
            }
            guard amount >= 0, amount.isFinite else { continue }
            let start = max(a.timestamp, since)
            result.append(InsightInterval(start: start, end: b.timestamp, amount: amount * b.timestamp.timeIntervalSince(start) / duration))
        }
        return result
    }
    public static func rates(_ points: [UsageHistoryPoint], kind: ConnectionKind, metric: InsightMetric = .weekly, since: Date, now: Date, bucketHours: Int = 1) -> [InsightRateBucket] {
        let span = Double(max(1, min(24, bucketHours))) * 3600
        var buckets: [Int: (amount: Double, seconds: Double)] = [:]
        for interval in intervals(points, kind: kind, metric: metric, since: since, now: now) {
            var cursor = interval.start
            while cursor < interval.end {
                let key = Int(floor(cursor.timeIntervalSince1970 / span))
                let end = min(interval.end, Date(timeIntervalSince1970: Double(key + 1) * span))
                let seconds = end.timeIntervalSince(cursor)
                guard seconds > 0 else { break }
                var bucket = buckets[key] ?? (0,0)
                bucket.amount += interval.amount * seconds / interval.seconds
                bucket.seconds += seconds; buckets[key] = bucket; cursor = end
            }
        }
        var previous: Int?, segment = 0
        return buckets.keys.sorted().compactMap { key in
            guard let bucket = buckets[key], bucket.seconds >= 300 else { return nil }
            if let previous, key != previous + 1 { segment += 1 }
            previous = key
            return InsightRateBucket(start: max(since, Date(timeIntervalSince1970: Double(key) * span)),
                end: min(now, Date(timeIntervalSince1970: Double(key + 1) * span)), amount: bucket.amount, measuredSeconds: bucket.seconds, segment: segment)
        }
    }
    public static func allowanceSeries(_ points: [UsageHistoryPoint], kind: ConnectionKind, session: Bool, since: Date, now: Date) -> [InsightAllowancePoint] {
        var result: [InsightAllowancePoint] = [], previous: UsageHistoryPoint?, segment = 0
        for point in points.suffix(SnapshotCache.maximumPoints) where point.timestamp >= since && point.timestamp <= now {
            guard let remaining = value(point, kind: kind, metric: session ? .session : .weekly) else { previous = nil; segment += 1; continue }
            if let previous {
                let time = point.timestamp.timeIntervalSince(previous.timestamp)
                let sameWindow = session ? matchesReset(previous.sessionResetsAt, point.sessionResetsAt)
                    : previous.windowID == point.windowID && matchesReset(previous.resetsAt, point.resetsAt)
                if !sameWindow || time <= 0 || time > max(previous.continuityInterval ?? 1800, point.continuityInterval ?? 1800)
                    || remaining > (value(previous, kind: kind, metric: session ? .session : .weekly) ?? 100) { segment += 1 }
            }
            result.append(InsightAllowancePoint(timestamp: point.timestamp, remaining: remaining, segment: segment)); previous = point
        }
        return HistorySeries.plotSamples(result.map { HistorySample(timestamp: $0.timestamp, value: $0.remaining, segment: $0.segment) }, maximum: 180)
            .map { InsightAllowancePoint(timestamp: $0.timestamp, remaining: $0.value, segment: $0.segment) }
    }
    public static func weeklyPace(points: [UsageHistoryPoint], snapshot: Snapshot?, kind: ConnectionKind, fresh: Bool, now: Date) -> WeeklyPace? {
        guard !kind.isAPI, let snapshot, snapshot.unlimited != true,
              let window = snapshot.primaryWeeklyWindow(for: kind), window.durationMinutes == 10080,
              let reset = window.resetsAt, reset > now, reset.timeIntervalSince(now) <= 7 * 86400 + 120 else { return nil }
        let start = reset.addingTimeInterval(-7 * 86400)
        let history = points.filter { $0.timestamp >= start && $0.windowID == window.id && matchesReset($0.resetsAt,reset) }
        let intervals = intervals(history, kind: kind, since: start, now: now)
        let covered = intervals.reduce(0) { $0 + $1.seconds }, spent = intervals.reduce(0) { $0 + $1.amount }
        let rate = fresh && snapshot.providerRestricted != true && !snapshot.isStale(at: now, windows: [window]) && covered >= 6 * 3600 && intervals.count >= 4 && spent > 0 ? spent / covered : nil
        let remainingAtReset = rate.map { min(100, max(0, window.remainingPercent - $0 * reset.timeIntervalSince(snapshot.observedAt))) }
        let exhaustion = rate.flatMap { rate -> Date? in
            let date = snapshot.observedAt.addingTimeInterval(window.remainingPercent / rate)
            return date < reset ? date : nil
        }
        return WeeklyPace(cycleStart: start, resetAt: reset, observedAt: snapshot.observedAt, remaining: window.remainingPercent,
            measuredSeconds: covered, points: allowanceSeries(history, kind: kind, session: false, since: start, now: now),
            pointsPerDay: rate.map { $0 * 86400 }, estimatedRemaining: remainingAtReset, estimatedExhaustion: exhaustion)
    }
    public static func calendar(days: [UsageDay], kind: ConnectionKind, metric: InsightMetric = .weekly, count: Int, now: Date) -> InsightCalendar {
        let count = max(1, min(360, count))
        let today = HistoryTrends.calendar.startOfDay(for: now), start = today.addingTimeInterval(-Double(count - 1) * 86400)
        var recorded: [Date: MeasuredUsage] = [:]
        for day in days where day.day >= start && day.day <= today {
            guard let value = kind.isAPI ? day.money : metric == .session ? day.session : day.weekly,
                  value.amount.isFinite, value.amount >= 0, value.seconds.isFinite, value.seconds > 0 else { continue }
            recorded[day.day] = value
        }
        return InsightCalendar(days: (0..<count).map { offset in
            let date = start.addingTimeInterval(Double(offset) * 86400), value = recorded[date]
            return InsightCalendarDay(date: date, amount: value?.amount, measuredSeconds: value?.seconds ?? 0)
        })
    }
    public static func creditRunway(days: [UsageDay], snapshot: Snapshot?, kind: ConnectionKind, periodDays: Int, fresh: Bool, now: Date) -> CreditRunway? {
        guard kind.isBalance, let snapshot, let balance = snapshot.balanceUSD.map({ NSDecimalNumber(decimal: $0).doubleValue }), balance.isFinite else { return nil }
        let today = HistoryTrends.calendar.startOfDay(for: now)
        let start = today.addingTimeInterval(-Double(max(3, min(30, periodDays))) * 86400)
        let measured = days.filter { $0.day >= start && $0.day < today }.compactMap(\.money)
            .filter { $0.amount.isFinite && $0.amount >= 0 && $0.seconds.isFinite && $0.seconds >= 3600 }
        let spent = measured.reduce(0) { $0 + $1.amount }, covered = measured.reduce(0) { $0 + $1.seconds }
        let daily = fresh && snapshot.providerRestricted != true && !snapshot.isStale(at: now) && measured.count >= 3 && covered >= 12 * 3600 && spent > 0 ? spent / covered * 86400 : nil
        let left = daily.flatMap { rate -> Double? in let value = max(0,balance) / rate; return value.isFinite ? value : nil }
        return CreditRunway(balance: balance, observedSpending: spent, measuredSeconds: covered, measuredDays: measured.count,
            estimatedDailySpending: daily, estimatedDaysLeft: left)
    }
}
