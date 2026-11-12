import SwiftUI
import UsageCore

private struct DashboardSpanKey: LayoutValueKey { static let defaultValue = 1 }
private struct DashboardMinimumSpanKey: LayoutValueKey { static let defaultValue = 1 }
extension View {
    func dashboardSpan(_ span: Int, minimum: Int = 1) -> some View {
        layoutValue(key: DashboardSpanKey.self, value: span).layoutValue(key: DashboardMinimumSpanKey.self, value: minimum)
    }
}

/// Natural-height tiles fill the shortest available column. Summary tiles prefer
/// two columns, but become compact tiles when that closes a collapsed-card gap.
struct DashboardGrid: Layout {
    let accountCount: Int
    private func plan(width: CGFloat, subviews: Subviews) -> DashboardGridPlan {
        let columns = DashboardGridPlan.columns(width: width, accounts: accountCount)
        let columnWidth = max(0, (width - CGFloat(columns - 1) * 12) / CGFloat(columns))
        let items = subviews.map { view in
            let maximumSpan = max(1, min(columns, view[DashboardSpanKey.self]))
            let minimumSpan = max(1, min(maximumSpan, view[DashboardMinimumSpanKey.self]))
            return DashboardGridItem(heights: (1...maximumSpan).map { span in
                // Exact-width cards do not need charts laid out at discarded widths.
                guard span >= minimumSpan else { return 0 }
                let proposed = columnWidth * CGFloat(span) + CGFloat(span - 1) * 12
                return view.sizeThatFits(ProposedViewSize(width: proposed, height: nil)).height
            }, minimumSpan: minimumSpan)
        }
        return DashboardGridPlan(width: width, columns: columns, items: items)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 760
        return CGSize(width: width, height: plan(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, plan(width: bounds.width, subviews: subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
