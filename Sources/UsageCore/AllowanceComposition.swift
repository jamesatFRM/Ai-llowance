import Foundation

/// Match the conservative whole-percent headline while keeping the chart's
/// actual fractional geometry and complementary displayed labels.
public struct AllowanceComposition: Equatable, Sendable {
    public let remainingPercent: Double
    public var remainingWholePercent: Int { Int(remainingPercent) }
    public var usedWholePercent: Int { 100 - remainingWholePercent }
    public init?(_ percent: Double?) {
        guard let percent, percent.isFinite else { return nil }
        remainingPercent = min(100, max(0, percent))
    }
}
