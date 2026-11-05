import Foundation

/// Balanced rows keep the final account from becoming an oversized full-width card.
public struct AccountGridLayout: Equatable, Sendable {
    public let rowCounts: [Int]
    public let cardWidth: Double
    public static let spacing = 12.0

    public init(count: Int, width: Double) {
        let width = width.isFinite ? max(0, width) : 0
        guard count > 0 else { rowCounts = []; cardWidth = 0; return }
        let capacity = max(1, min(4, Int((width + Self.spacing) / 280)))
        let rows = (count + capacity - 1) / capacity
        let columns = (count + rows - 1) / rows
        rowCounts = (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
        cardWidth = max(0, (width - Double(columns - 1) * Self.spacing) / Double(columns))
    }
}
