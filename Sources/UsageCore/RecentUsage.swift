import Foundation

/// Fixed, small consumption buckets for the dropdown sparkline. Nil means unmeasured.
public enum RecentUsage {
    public static func buckets(_ history: [UsageHistoryPoint], kind: ConnectionKind, now: Date) -> [Double?] {
        let width: TimeInterval = 900
        let start = now.addingTimeInterval(-6 * 3600)
        var values = [Double?](repeating: nil, count: 24)
        let intervals = zip(history, history.dropFirst())
            .filter { $0.1.timestamp > start && $0.0.timestamp < now }
            .map { (previous: $0.0, current: $0.1, days: ConsumptionHistory.append([], previous: $0.0, current: $0.1, kind: kind)) }
        // A weekly point and a session point represent different capacities.
        // Choose one metric for this whole graph rather than creating false spikes.
        let weekly = intervals.contains { $0.days.contains { $0.weekly != nil } }
        for interval in intervals {
            let previous = interval.previous, current = interval.current
            let measured = interval.days.compactMap { kind.isAPI ? $0.money : weekly ? $0.weekly : $0.session }
            guard !measured.isEmpty else { continue }
            let amount = measured.reduce(0) { $0 + $1.amount }
            let duration = current.timestamp.timeIntervalSince(previous.timestamp)
            guard duration > 0 else { continue }
            var cursor = max(start, previous.timestamp)
            let stop = min(now, current.timestamp)
            while cursor < stop {
                let index = min(23, Int(cursor.timeIntervalSince(start) / width))
                let end = min(stop, start.addingTimeInterval(Double(index + 1) * width))
                values[index] = (values[index] ?? 0) + amount * end.timeIntervalSince(cursor) / duration
                cursor = end
            }
        }
        return values
    }
}
