import Foundation

/// Observed subscription allowance consumption, never inferred coding time.
public enum UsageHeatmap {
    public static func hours(points: [UsageHistoryPoint], kind: ConnectionKind, calendar: Calendar = .current) -> [Date: Double] {
        guard !kind.isAPI else { return [:] }
        let samples = HistorySeries.samples(points, kind: kind)
        var buckets: [Date: Double] = [:]
        for (previous, current) in zip(samples, samples.dropFirst()) {
            guard previous.segment == current.segment else { continue }
            let duration = current.timestamp.timeIntervalSince(previous.timestamp)
            guard duration > 0 else { continue }
            let consumed = max(0, previous.value - current.value)
            var cursor = previous.timestamp
            while cursor < current.timestamp {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let end = min(hour.end, current.timestamp)
                guard end > cursor else { break }
                buckets[hour.start, default: 0] += consumed * end.timeIntervalSince(cursor) / duration
                cursor = end
            }
        }
        return buckets
    }
}
