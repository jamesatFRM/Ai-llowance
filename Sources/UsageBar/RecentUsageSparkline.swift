import SwiftUI
import UsageCore

struct RecentUsageSparkline: View {
    let history: [UsageHistoryPoint]
    let kind: ConnectionKind
    let now: Date
    let tint: Color

    var body: some View {
        let buckets = RecentUsage.buckets(history, kind: kind, now: now)
        let peak = max(0.01, buckets.compactMap { $0 }.max() ?? 0)
        Canvas { context, size in
            var run: [CGPoint] = []
            func drawRun() {
                guard let first = run.first, let last = run.last else { return }
                var line = Path(); line.move(to: first)
                for (a, b) in zip(run, run.dropFirst()) {
                    let mid = (a.x + b.x) / 2
                    line.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
                }
                var fill = line
                fill.addLine(to: CGPoint(x: last.x, y: size.height))
                fill.addLine(to: CGPoint(x: first.x, y: size.height)); fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                if run.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1, y: first.y - 1, width: 2, height: 2)), with: .color(tint))
                } else {
                    context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
            for (index, value) in buckets.enumerated() {
                guard let value else { drawRun(); run.removeAll(keepingCapacity: true); continue }
                run.append(CGPoint(x: 1 + Double(index) / 23 * (size.width - 2), y: size.height - 2 - value / peak * (size.height - 4)))
            }
            drawRun()
            if buckets.allSatisfy({ $0 == nil }) {
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: size.height / 2)); baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .accessibilityLabel(buckets.allSatisfy { $0 == nil } ? "Recent usage: no measured intervals" : "Recent usage: last 6 hours, relative consumption")
        .help("Observed consumption · last 6 hours · 15-minute buckets. Height is relative to this account’s peak. Gaps are unmeasured.")
    }
}
