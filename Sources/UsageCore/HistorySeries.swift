import Foundation

public struct HistorySample: Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let value: Double
    public let segment: Int
}

/// Lines connect only nearby observations from the same known reporting period.
public enum HistorySeries {
    /// A bounded visual trend. Never blends across missing intervals or quota resets.
    /// Exact observations remain the source for values and inspection.
    public static func smoothTrend(_ samples: [HistorySample]) -> [HistorySample] {
        var result = samples
        for _ in 0..<2 {
            let source = result
            result = source.indices.map { index in
                guard index > 0, index + 1 < source.count,
                      source[index - 1].segment == source[index].segment,
                      source[index + 1].segment == source[index].segment else { return source[index] }
                let value = (source[index - 1].value + 2 * source[index].value + source[index + 1].value) / 4
                return HistorySample(timestamp: source[index].timestamp, value: value, segment: source[index].segment)
            }
        }
        return result
    }

    /// Cumulative observed drops within comparable quota windows. Resets and unmeasured gaps add nothing.
    public static func consumption(_ samples: [HistorySample]) -> [HistorySample] {
        var total = 0.0
        var previous: HistorySample?
        return samples.map { sample in
            if let previous, previous.segment == sample.segment {
                total += max(0, previous.value - sample.value)
            }
            previous = sample
            return HistorySample(timestamp: sample.timestamp, value: total, segment: sample.segment)
        }
    }

    public static func samples(_ points: [UsageHistoryPoint], kind: ConnectionKind) -> [HistorySample] {
        var result: [HistorySample] = []
        var previous: UsageHistoryPoint?
        var segment = 0
        for point in points {
            let value: Double?
            if kind.isBalance { value = point.balanceUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            else if kind.isAPI { value = point.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            else { value = point.remainingPercent }
            guard let value, value.isFinite else { previous = nil; segment += 1; continue }
            if let previous, let last = result.last {
                let gap = point.timestamp.timeIntervalSince(previous.timestamp)
                let resetChanged: Bool
                switch (previous.resetsAt, point.resetsAt) {
                case let (.some(a), .some(b)): resetChanged = abs(a.timeIntervalSince(b)) > 120
                case (.none, .none): resetChanged = false
                default: resetChanged = true
                }
                let changedWindow = !kind.isAPI && (point.windowID != previous.windowID || resetChanged)
                let restoredQuota = !kind.isAPI && value > last.value
                let newBillingPeriod = kind.isAPI && !kind.isBalance && value < last.value
                if gap <= 0 || gap > 1800 || changedWindow || restoredQuota || newBillingPeriod { segment += 1 }
            }
            result.append(HistorySample(timestamp: point.timestamp, value: value, segment: segment))
            previous = point
        }
        return result
    }
}
