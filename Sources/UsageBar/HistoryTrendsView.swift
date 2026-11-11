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
    private var accounts: [Account] { store.orderedDashboardAccounts.filter { accountID == nil || $0.id == accountID } }
    private var start: Date { HistoryTrends.calendar.date(byAdding: .day, value: 1 - days, to: HistoryTrends.calendar.startOfDay(for: store.now))! }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.demo ? "History · Sample data" : "History").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("See how your usage changes over time.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                AppDropdown(accountID.flatMap { id in store.accounts.first { $0.id == id }?.name } ?? "All accounts", symbol: "person.2", menuTitle: "Show accounts") {
                    AppDropdownItem("All accounts", symbol: "person.2", selected: accountID == nil) { accountID = nil }
                    AppDropdownItem.separator
                    for account in store.accounts {
                        AppDropdownItem(account.pickerLabel, symbol: "person.crop.circle", selected: accountID == account.id) { accountID = account.id }
                    }
                }.frame(width: 180).accessibilityLabel("History account filter")
            }
            HStack(spacing: 16) {
                Picker("History range", selection: $days) {
                    ForEach(HistoryTrends.ranges, id: \.self) { Text("\($0)d").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 470)
                Spacer(minLength: 0)
                Picker("Quota window", selection: $session) {
                    Text("Weekly").tag(false)
                    Text("5-hour").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 164).disabled(accounts.allSatisfy { $0.kind.isAPI }).help("Quota window for subscription accounts. API accounts always show dollars.")
            }
            if accounts.isEmpty {
                ContentUnavailableView("No accounts yet", systemImage: "chart.bar.xaxis", description: Text("Connect an account to start building your history."))
            }
            ForEach(accounts) { account in
                let recorded = store.usageDays[account.id] ?? []
                let samples = ConsumptionHistory.buckets(recorded, kind: account.kind, session: session, since: start, now: store.now, weekly: days >= 60)
                let summary = ConsumptionSummary(days: recorded, kind: account.kind, session: session, since: start, now: store.now)
                HistoryTrendPanel(account: account, samples: samples, summary: summary, firstRecorded: recorded.first(where: { account.kind.isAPI ? $0.money != nil : session ? $0.session != nil : $0.weekly != nil })?.day, start: start, end: store.now, days: days, session: session)
            }
            Label("Stored on this Mac · 7 days of detail, 400-day retention for daily summaries (UTC)", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Bars show observed consumption, excluding refills and resets. Faded bars have incomplete coverage; gaps are unmeasured. One allowance point is 1% of that account’s limit. Different plans have different capacities; points are not comparable tokens or dollars. Weekly and 5-hour usage stay separate. Usage is never projected into unmeasured time.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(8).environment(\.calendar, HistoryTrends.calendar).environment(\.timeZone, HistoryTrends.calendar.timeZone)
            .onChange(of: store.accounts.map(\.id)) { _, ids in
                if let accountID, !ids.contains(accountID) { self.accountID = nil }
            }
    }
}

private struct HistoryTrendPanel: View {
    let account: Account
    let samples: [ConsumptionBucket]
    let summary: ConsumptionSummary
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
                    Text(samples.isEmpty ? "No measured intervals" : String(format: "%.1f %@ observed", summary.amount, account.kind.isAPI ? "USD" : "points"))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
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
                            .accessibilityLabel(dateText(sample.start))
                            .accessibilityValue(value(sample) + String(format: ", %.0f percent time coverage", sample.coverage(at: end) * 100))
                        if sample.amount == 0 {
                            PointMark(x: .value("Period", sample.midpoint), y: .value(metric, 0))
                                .symbolSize(12).foregroundStyle(tint.opacity(0.65))
                                .accessibilityLabel("Measured zero usage on " + dateText(sample.start))
                        }
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
                    if let selected { Text(dateText(selected.start) + " · " + value(selected) + String(format: " · %.0f%% coverage", selected.coverage(at: end) * 100)) }
                    else { Text(days >= 60 ? "Weekly totals · line: 3-week average" : "Daily observed usage · hover to inspect") }
                    Spacer()
                    if let firstRecorded { Text("Available since " + dateText(firstRecorded)) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 10) {
                    GeometryReader { geometry in
                        Capsule().fill(Color.primary.opacity(0.06))
                            .overlay(alignment: .leading) { Capsule().fill(tint.opacity(0.65)).frame(width: geometry.size.width * summary.coverage) }
                    }.frame(width: 70, height: 4).accessibilityHidden(true)
                    Text(String(format: "%.0f%% of selected time measured", summary.coverage * 100))
                    Spacer()
                    Text("\(summary.measuredDays) days with readings")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Coverage is the time between consecutive usable readings. Zero means measured zero; gaps have no reading. Totals are not estimates for the entire range.")
            }
        }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)))
    }
}
