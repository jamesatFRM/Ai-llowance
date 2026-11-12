import Foundation

public struct DashboardGridItem: Sendable {
    /// One natural height for each permitted column span, starting at one.
    public let heights: [Double]
    public let minimumSpan: Int
    public init(heights: [Double], minimumSpan: Int = 1) { self.heights = heights; self.minimumSpan = minimumSpan }
}
public struct DashboardTileFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let span: Int
}
public struct DashboardGridPlan: Sendable {
    public let frames: [DashboardTileFrame]
    public let height: Double
    public static let spacing = 12.0
    public static func columns(width: Double, accounts: Int) -> Int {
        AccountGridLayout(count: max(1, accounts), width: width).rowCounts.max() ?? 1
    }
    public init(width: Double, columns: Int, items: [DashboardGridItem]) {
        let width = width.isFinite ? max(0, width) : 0
        let columns = max(1, min(4, columns))
        let columnWidth = max(0, (width - Double(columns - 1) * Self.spacing) / Double(columns))
        var bottoms = Array(repeating: 0.0, count: columns)
        var frames: [DashboardTileFrame] = []
        for item in items {
            var chosen: DashboardTileFrame?
            let maximumSpan = max(1, min(columns, item.heights.count))
            for span in max(1, min(maximumSpan, item.minimumSpan))...maximumSpan {
                let proposedHeight = item.heights.isEmpty ? 0 : item.heights[span - 1]
                let height = proposedHeight.isFinite ? max(0, proposedHeight) : 0
                for column in 0...(columns - span) {
                    let y = bottoms[column..<(column + span)].max() ?? 0
                    let candidate = DashboardTileFrame(x: Double(column) * (columnWidth + Self.spacing), y: y,
                        width: columnWidth * Double(span) + Double(span - 1) * Self.spacing, height: height, span: span)
                    if let old = chosen {
                        // Prefer the intended wide summary across small card-height
                        // differences; use a narrow tile for a substantial collapse gap.
                        let preferredSpan = max(1, min(columns, item.heights.count))
                        let finish = candidate.y + candidate.height + Double(preferredSpan - candidate.span) * 64
                        let oldFinish = old.y + old.height + Double(preferredSpan - old.span) * 64
                        if finish > oldFinish + 0.5 || (abs(finish - oldFinish) <= 0.5 && candidate.span <= old.span) { continue }
                    }
                    chosen = candidate
                }
            }
            let frame = chosen!
            let start = Int((frame.x / max(1, columnWidth + Self.spacing)).rounded())
            for column in start..<(start + frame.span) { bottoms[column] = frame.y + frame.height + Self.spacing }
            frames.append(frame)
        }
        self.frames = frames
        height = max(0, (bottoms.max() ?? 0) - Self.spacing)
    }
}
