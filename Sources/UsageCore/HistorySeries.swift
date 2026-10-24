import Foundation

public struct HistorySample: Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let value: Double
    public let segment: Int
}

/// Lines connect only nearby observations from the same known reporting period.
public enum HistorySeries {
    /// A labeled detail scale for percentage trends; bars retain a zero baseline.
    public static func allowanceTrendDomain(_ values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter { $0.isFinite && (0...100).contains($0) }
        guard let minimum = finite.min(), let maximum = finite.max() else { return 0...100 }
        var lower = max(0, floor((minimum - 2) / 5) * 5)
        var upper = min(100, ceil((maximum + 2) / 5) * 5)
        if upper - lower < 10 {
            lower = max(0, upper - 10)
            upper = min(100, lower + 10)
        }
        return lower...upper
    }

    /// One actual reading per time bucket; never averages percentages or fills missing buckets.
    public static func barSamples(_ samples: [HistorySample], count: Int = 24) -> [HistorySample] {
        guard count > 0, let first = samples.first, let last = samples.last else { return [] }
        let interval = max(1, last.timestamp.timeIntervalSince(first.timestamp) / Double(count))
        var buckets: [Int: HistorySample] = [:]
        for sample in samples {
            let index = min(count - 1, max(0, Int(sample.timestamp.timeIntervalSince(first.timestamp) / interval)))
            buckets[index] = sample
        }
        return buckets.keys.sorted().compactMap { buckets[$0] }
    }

    /// A bounded visual trend. Never blends across missing intervals or quota resets.
    /// Exact observations remain the source for values and inspection.
    public static func smoothTrend(_ samples: [HistorySample]) -> [HistorySample] {
        // Smooth by elapsed time, not sample count: frequent polling should not
        // turn the same history into tiny stair steps. Endpoints stay exact.
        let radius: TimeInterval = 3600
        return samples.enumerated().map { index, sample in
            guard index > 0, index + 1 < samples.count,
                  samples[index - 1].segment == sample.segment,
                  samples[index + 1].segment == sample.segment else { return sample }
            var lower = index
            var upper = index
            while lower > 0, samples[lower - 1].segment == sample.segment,
                  sample.timestamp.timeIntervalSince(samples[lower - 1].timestamp) < radius { lower -= 1 }
            while upper + 1 < samples.count, samples[upper + 1].segment == sample.segment,
                  samples[upper + 1].timestamp.timeIntervalSince(sample.timestamp) < radius { upper += 1 }
            var weighted = 0.0
            var weight = 0.0
            for neighbor in samples[lower...upper] {
                let distance = abs(neighbor.timestamp.timeIntervalSince(sample.timestamp))
                guard distance < radius else { continue }
                let influence = pow(1 - pow(distance / radius, 3), 3)
                weighted += neighbor.value * influence
                weight += influence
            }
            return HistorySample(timestamp: sample.timestamp, value: weight > 0 ? weighted / weight : sample.value, segment: sample.segment)
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
