import SwiftUI
import Charts
import UsageCore

struct AccountComparisonChart: View {
    let comparison: UsageComparison
    let style: DashboardChartStyle
    let tint: Color
    let isMoney: Bool
    private struct Sample: Identifiable {
        let index: Int
        let value: Double
        let previous: Bool
        let segment: Int
        var id: String { "\(previous)-\(index)" }
        var series: String { "\(previous)-\(segment)" }
    }
    private var samples: [Sample] {
        [false, true].flatMap { previous -> [Sample] in
            var segment = 0
            return comparison.days.enumerated().compactMap { index, day -> Sample? in
                guard let value = previous ? day.previous : day.current else { segment += 1; return nil }
                return Sample(index: index, value: value.amount, previous: previous, segment: segment)
            }
        }
    }
    private func amount(_ value: Double) -> String { String(format: isMoney ? "$%.2f" : "%.0f pts", value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(isMoney ? "Observed use · USD" : "Weekly use · points")
                Spacer(minLength: 0)
                Text("7d · UTC")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            if samples.isEmpty {
                Text("Matched history is building")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 86)
            } else if style.isCurrentAllowance {
                HStack(spacing: 12) {
                    if comparison.currentAmount + comparison.previousAmount > 0 {
                        if style == .gauge {
                            let share = comparison.currentAmount / (comparison.currentAmount + comparison.previousAmount)
                            ZStack {
                                Circle().trim(from: 0, to: 0.75).stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                Circle().trim(from: 0, to: 0.75 * share).stroke(tint.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                Text(amount(comparison.currentAmount)).font(.system(size: 11, weight: .semibold)).rotationEffect(.degrees(-135))
                            }.rotationEffect(.degrees(135)).padding(6).frame(width: 76, height: 76)
                        } else {
                        Chart {
                            SectorMark(angle: .value("This period", comparison.currentAmount), innerRadius: .ratio(style == .pie ? 0 : 0.76), angularInset: 3)
                                .foregroundStyle(tint.gradient).cornerRadius(3)
                            SectorMark(angle: .value("Earlier period", comparison.previousAmount), innerRadius: .ratio(style == .pie ? 0 : 0.76), angularInset: 3)
                                .foregroundStyle(Color.secondary.opacity(0.3)).cornerRadius(3)
                        }.frame(width: 76, height: 76).chartLegend(.hidden)
                        }
                    }
                    Text("Usage share\nMatched days only").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.frame(height: 86)
            } else {
                let samples = self.samples
                Chart {
                    ForEach(samples) { sample in
                        if style == .bars {
                            BarMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value))
                                .position(by: .value("Period", sample.previous ? "Previous" : "Current"))
                                .foregroundStyle(sample.previous ? Color.secondary.opacity(0.25) : tint.opacity(0.9))
                                .cornerRadius(3)
                        } else if style == .dots {
                            PointMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value))
                                .foregroundStyle(sample.previous ? Color.secondary.opacity(0.55) : tint).symbolSize(sample.previous ? 13 : 20)
                        } else if style == .matrix {
                            PointMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value)).foregroundStyle(Color.clear).symbolSize(0)
                        } else {
                            if !sample.previous && (style == .glow || style == .area) {
                                AreaMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value), series: .value("Series", "area-" + sample.series))
                                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                            }
                            if !sample.previous && style == .glow {
                                LineMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value), series: .value("Series", "halo-" + sample.series))
                                    .foregroundStyle(tint.opacity(0.15)).lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value), series: .value("Series", sample.series))
                                .foregroundStyle(sample.previous ? Color.secondary.opacity(0.6) : tint)
                                .lineStyle(StrokeStyle(lineWidth: sample.previous ? 1.5 : 2.3, lineCap: .round, lineJoin: .round, dash: sample.previous ? [3, 4] : []))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", sample.index), y: .value("Observed usage", sample.value))
                                .foregroundStyle(sample.previous ? Color.secondary.opacity(0.5) : tint).symbolSize(9)
                        }
                    }
                }
                .chartXScale(domain: -0.45...6.45)
                .chartYScale(domain: 0...max(1, (samples.map(\.value).max() ?? 1) * 1.15))
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: [0, 3, 6]) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self), comparison.days.indices.contains(index) {
                                Text(comparison.days[index].day, format: .dateTime.weekday(.abbreviated)).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(Color.primary.opacity(0.06)); AxisValueLabel().font(.system(size: 8)) } }
                .chartOverlay { proxy in
                    if style == .matrix {
                        GeometryReader { geometry in
                            if let plotFrame = proxy.plotFrame {
                                let frame = geometry[plotFrame]
                                ForEach([true, false], id: \.self) { previous in
                                    DotMatrixPlot(points: samples.filter { $0.previous == previous }.compactMap { sample in
                                        guard let x = proxy.position(forX: sample.index), let y = proxy.position(forY: sample.value) else { return nil }
                                        return MatrixPoint(x: x, y: y, segment: sample.segment)
                                    }, tint: previous ? Color.secondary.opacity(0.5) : tint)
                                    .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                                }
                            }
                        }.allowsHitTesting(false)
                    }
                }
                .frame(height: 86)
            }
            HStack(spacing: 8) {
                Label("Matched " + (comparison.pairedDays == 0 ? "—" : amount(comparison.currentAmount)), systemImage: "circle.fill").foregroundStyle(tint)
                Spacer(minLength: 0)
                Label(comparison.period.previousLabel.capitalized + " " + (comparison.pairedDays == 0 ? "—" : amount(comparison.previousAmount)), systemImage: "circle.dashed").foregroundStyle(.secondary)
            }.font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
        }.help(comparison.detail)
        .environment(\.calendar, HistoryTrends.calendar).environment(\.timeZone, HistoryTrends.calendar.timeZone)
    }
}
