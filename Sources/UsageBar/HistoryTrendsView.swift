import SwiftUI
import AppKit
private typealias HistoryViewState<Value> = SwiftUI.State<Value>
import Charts
import UsageCore

struct HistoryTrendsView: View {
    @ObservedObject var store: AppStore
    @AppStorage("historyRangeDays") private var days = 30
    @HistoryViewState private var accountID: UUID?
    @AppStorage("historyQuotaSession") private var session = false
    private var accounts: [Account] { store.accounts.filter { accountID == nil || $0.id == accountID } }
    private var start: Date { HistoryTrends.calendar.date(byAdding: .day, value: 1 - days, to: HistoryTrends.calendar.startOfDay(for: store.now))! }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.demo ? "History · Sample data" : "History").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("See how your usage changes over time.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Account", selection: $accountID) {
                    Text("All accounts").tag(nil as UUID?)
                    ForEach(store.accounts) { Text($0.name + " · " + $0.kind.provider.title).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 180)
            }
            HStack(spacing: 16) {
                Picker("History range", selection: $days) {
                    ForEach(HistoryTrends.ranges, id: \.self) { Text("\($0)d").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 470)
                Spacer(minLength: 0)
                Picker("Quota window", selection: $session) {
                    Text("Weekly").tag(false)
                    Text("5-hour").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 164).help("Quota window for subscription accounts. API accounts always show dollars.")
            }
            if accounts.isEmpty {
                ContentUnavailableView("No accounts yet", systemImage: "chart.bar.xaxis", description: Text("Connect an account to start building your history."))
            }
            ForEach(accounts) { account in
                let recorded = store.usageDays[account.id] ?? []
                let samples = ConsumptionHistory.buckets(recorded, kind: account.kind, session: session, since: start, now: store.now, weekly: days >= 60)
                HistoryTrendPanel(account: account, samples: samples, firstRecorded: recorded.first(where: { account.kind.isAPI ? $0.money != nil : session ? $0.session != nil : $0.weekly != nil })?.day, start: start, end: store.now, days: days, session: session)
            }
            Label("Stored on this Mac · 7 days of detail, up to 360 days of usage summaries (UTC)", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Bars show observed consumption, excluding refills and resets. Faded bars have incomplete coverage; gaps are unmeasured. Subscription usage is measured in allowance points, not tokens. Weekly and 5-hour usage stay separate.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(8).environment(\.calendar, HistoryTrends.calendar).environment(\.timeZone, HistoryTrends.calendar.timeZone)
    }
}

private struct HistoryTrendPanel: View {
    let account: Account
    let samples: [ConsumptionBucket]
    let firstRecorded: Date?
    let start: Date
    let end: Date
    let days: Int
    let session: Bool
    @HistoryViewState private var hovered: Date?
    private var tint: Color {
        if let hex = account.graphColorHex, let value = UInt64(hex, radix: 16) {
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        return account.kind == .claudeCode || account.kind == .claudeAPI ? .orange : .teal
    }
    private var metric: String { account.kind.isBalance ? "Observed credit decrease · USD" : account.kind.isAPI ? "Observed spending · USD" : session ? "5-hour allowance used · points" : "Weekly allowance used · points" }
    private var selected: ConsumptionBucket? {
        guard let hovered else { return nil }
        return samples.first { $0.start <= hovered && hovered < $0.end }
    }
    private func dateText(_ date: Date, time: Bool = false) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted, timeZone: HistoryTrends.calendar.timeZone))
    }
    private func value(_ sample: ConsumptionBucket) -> String {
        account.kind.isAPI ? String(format: "$%.2f", sample.amount) : String(format: "%.1f points used", sample.amount)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.name).font(.system(size: 15, weight: .semibold))
                    Text(account.expectedIdentity ?? account.kind.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(metric).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                    Text(samples.contains(where: \.partial) ? "Observed usage · incomplete coverage" : "Observed usage").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if samples.isEmpty {
                VStack(spacing: 6) {
                    Text("No measured usage in this range").font(.system(size: 13, weight: .medium))
                    Text(session && !account.kind.isAPI ? "5-hour usage builds from consecutive readings when your plan reports this limit." : "Usage builds from consecutive readings. Older closing balances cannot reconstruct consumption.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 150)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        RectangleMark(xStart: .value("Start", sample.start.addingTimeInterval(sample.end.timeIntervalSince(sample.start) * 0.14)), xEnd: .value("End", sample.end.addingTimeInterval(-sample.end.timeIntervalSince(sample.start) * 0.14)), yStart: .value("Baseline", 0), yEnd: .value(metric, sample.amount))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(sample.partial ? 0.48 : 0.85), tint.opacity(0.14)], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(3)
                        if days >= 60 && sample.end <= end {
                            LineMark(x: .value("Period", sample.midpoint), y: .value("Three-week average", sample.trend), series: .value("Segment", sample.segment))
                                .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if let selected, selected.id == sample.id {
                            RuleMark(x: .value("Selected period", sample.midpoint)).foregroundStyle(.secondary.opacity(0.4))
                        }
                    }
                }
                .chartXScale(domain: start...max(start.addingTimeInterval(86400), HistoryTrends.calendar.date(byAdding: .day, value: 1, to: HistoryTrends.calendar.startOfDay(for: end))!))
                .chartYScale(domain: 0...max(1, (samples.map(\.amount).max() ?? 1) * 1.12))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 10)); AxisGridLine().foregroundStyle(.secondary.opacity(0.06)) } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel().font(.system(size: 10)); AxisGridLine().foregroundStyle(.secondary.opacity(0.10)) } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard NSEvent.pressedMouseButtons == 0, let plot = proxy.plotFrame else { return }
                                let frame = geometry[plot]
                                let date: Date? = frame.contains(point) ? proxy.value(atX: point.x - frame.minX) : nil
                                let day = date.map { HistoryTrends.calendar.startOfDay(for: $0) }
                                if hovered != day { hovered = day }
                            case .ended: hovered = nil
                            }
                        }
                    }
                }.frame(height: 160)
                HStack {
                    if let selected { Text(dateText(selected.start) + " · " + value(selected) + (selected.partial ? " · partial coverage" : "")) }
                    else { Text(days >= 60 ? "Weekly totals · line: 3-week average" : "Daily observed usage · hover to inspect") }
                    Spacer()
                    if let firstRecorded { Text("Available since " + dateText(firstRecorded)) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)))
    }
}
