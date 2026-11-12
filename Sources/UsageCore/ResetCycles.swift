import Foundation

/// A closing observation, not a claim that the account was watched until reset.
public struct ResetCycle: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { resetAt }
    public let resetAt: Date
    public let lastObservedAt: Date
    public let remainingPercent: Double
    public let windowID: String
    public init(resetAt: Date, lastObservedAt: Date, remainingPercent: Double, windowID: String) {
        self.resetAt = resetAt; self.lastObservedAt = lastObservedAt
        self.remainingPercent = remainingPercent; self.windowID = windowID
    }
    public var observationGap: TimeInterval { max(0, resetAt.timeIntervalSince(lastObservedAt)) }
    public var valid: Bool {
        remainingPercent.isFinite && (0...100).contains(remainingPercent) && lastObservedAt <= resetAt
            && observationGap <= 86400 && !windowID.isEmpty && windowID.utf8.count <= 512
    }
}

public enum ResetCycles {
    public static func isWeekly(_ point: UsageHistoryPoint) -> Bool {
        if let duration = point.windowDurationMinutes { return duration == 10080 }
        let id = point.windowID?.lowercased() ?? ""
        return id.contains("week") || id == "7-day" || (id.hasPrefix("codex.") && (point.resetsAt?.timeIntervalSince(point.timestamp) ?? 0) > 5 * 3600)
    }
    public static func append(_ existing: [ResetCycle], previous: UsageHistoryPoint?, current: UsageHistoryPoint, kind: ConnectionKind) -> [ResetCycle] {
        var records = existing
        if !kind.isAPI, let previous, isWeekly(previous), isWeekly(current),
           previous.windowID == current.windowID, let windowID = previous.windowID,
           let reset = previous.resetsAt, let nextReset = current.resetsAt,
           current.timestamp >= reset, current.timestamp >= previous.timestamp,
           nextReset.timeIntervalSince(reset) > 120, let remaining = previous.remainingPercent {
            let record = ResetCycle(resetAt: reset, lastObservedAt: previous.timestamp, remainingPercent: remaining, windowID: windowID)
            if record.valid && !records.contains(where: { abs($0.resetAt.timeIntervalSince(reset)) <= 120 }) { records.append(record) }
        }
        let cutoff = current.timestamp.addingTimeInterval(-Double(SnapshotCache.retentionDays) * 86400)
        return records.filter { $0.valid && $0.resetAt >= cutoff && $0.resetAt <= current.timestamp }
            .sorted { $0.resetAt < $1.resetAt }.suffix(64).map { $0 }
    }
    public static func rebuild(_ points: [UsageHistoryPoint], kind: ConnectionKind) -> [ResetCycle] {
        var records: [ResetCycle] = []
        for (a,b) in zip(points, points.dropFirst()) { records = append(records, previous: a, current: b, kind: kind) }
        return records
    }
}
