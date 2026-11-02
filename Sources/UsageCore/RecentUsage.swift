import Foundation

/// Fixed, small consumption buckets for the dropdown sparkline. Nil means unmeasured.
public enum RecentUsage {
    public static func buckets(_ history: [UsageHistoryPoint], kind: ConnectionKind, now: Date) -> [Double?] {
        let width: TimeInterval = 900
        let start = now.addingTimeInterval(-6 * 3600)
        var values = [Double?](repeating: nil, count: 24)
        for (previous, current) in zip(history, history.dropFirst()) where current.timestamp > start && previous.timestamp < now {
            let days = ConsumptionHistory.append([], previous: previous, current: current, kind: kind)
            let measured = days.compactMap { kind.isAPI ? $0.money : ($0.weekly ?? $0.session) }
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
