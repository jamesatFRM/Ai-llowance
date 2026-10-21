import Foundation

public struct HistorySample: Identifiable, Sendable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let value: Double
    public let segment: Int
}

/// Lines connect only nearby observations from the same known reporting period.
public enum HistorySeries {
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
