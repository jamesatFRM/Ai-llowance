import AppKit
import Charts
import SwiftUI
import UsageCore

private typealias InsightState<Value> = SwiftUI.State<Value>

private func insightTint(_ kind: DashboardInsightKind, account: Account? = nil) -> Color {
    if let hex = account?.graphColorHex, let value = UInt64(hex, radix: 16) {
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    switch kind {
    case .weeklyPace: return .cyan
    case .unusedAllowance: return .mint
    case .limitPressure: return .orange
    case .burnRate: return Color(red: 0.69, green: 0.51, blue: 0.98)
    case .usageCalendar: return .teal
    case .creditRunway: return Color(red: 0.87, green: 0.67, blue: 0.31)
    }
}

struct DashboardInsightGallery: View {
    @ObservedObject var store: AppStore
    let preferredAccountID: UUID?
    let added: (UUID, UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @InsightState private var editing = false
    private var full: Bool { store.menuPreferences.dashboardLayout.insights.count >= DashboardLayoutPreferences.maximumInsights }
    private func eligible(_ kind: DashboardInsightKind) -> Bool { !full && store.accounts.contains { kind.supports($0.kind) } }
    private func title(_ id: String) -> String {
        if id == "overview" { return "Allowance use" }; if id == "activity" { return "Allowance activity" }
        if let account = store.accounts.first(where: { DashboardLayoutPreferences.accountTileID($0.id) == id }) { return insightAccountTitle(account) }
        return store.menuPreferences.dashboardLayout.insights.first { $0.tileID == id }?.kind.title ?? "View"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your dashboard").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Choose the views that work for you.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(QuietButtonStyle()).accessibilityLabel("Close dashboard customization")
            }
            Picker("Dashboard customization", selection: $editing) { Text("Add views").tag(false); Text("Your layout").tag(true) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            ScrollView {
                if editing { layoutList }
                else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(DashboardInsightKind.allCases) { kind in galleryTile(kind) }
                    }
                }
            }.scrollIndicators(.automatic)
            HStack(alignment: .center) {
                Label(full ? "12 optional views added" : "Calculated on this Mac · no extra refreshes", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if editing {
                    Button("Restore default layout") { store.restoreDashboardLayout() }
                        .font(.system(size: 11)).buttonStyle(.bordered)
                        .help("Restores the default arrangement. Keeps account names, colors and individual chart choices.")
                } else { Text("Illustrative previews").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }.padding(24).frame(width: 688, height: 680)
            .background(WorkspaceBackground(transparency: store.menuPreferences.dashboardTransparency))
            .preferredColorScheme(store.menuPreferences.theme.colorScheme).environment(\.liquidGlass, store.menuPreferences.liquidGlass)
    }
    private func galleryTile(_ kind: DashboardInsightKind) -> some View {
        let tint = insightTint(kind)
        return VStack(alignment: .leading, spacing: 10) {
            InsightThumbnail(kind: kind, tint: tint).frame(height: 48)
                .padding(.horizontal, 4).accessibilityHidden(true)
            HStack {
                Label(kind.title, systemImage: kind.symbol).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button {
                    if let id = store.addInsight(kind, accountID: preferredAccountID) {
                        let account = store.menuPreferences.dashboardLayout.insights.first { $0.id == id }?.accountID
                        added(id, account)
                    }
                } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(tint)
                    .background(tint.opacity(0.13), in: Circle()).disabled(!eligible(kind))
                    .accessibilityLabel("Add " + kind.title.lowercased())
            }
            Text(!eligible(kind) && !full ? (kind == .creditRunway ? "Connect an API credit account to use this view." : "Connect a compatible account to use this view.") : kind.subtitle)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
        }.padding(14).background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.10 : 0.07), Color.primary.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7))
        }
    }
    private var layoutList: some View {
        let ids = store.menuPreferences.dashboardLayout.arranged(store.dashboardTileIDs, includingHidden: true)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Hide a card without stopping its readings. Use the arrows to change its position.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 14)
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { !store.menuPreferences.dashboardLayout.hidden.contains(id) }, set: { store.setDashboardTileHidden(id, hidden: !$0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(id))
                            if let card = store.menuPreferences.dashboardLayout.insights.first(where: { $0.tileID == id }),
                               let account = store.accounts.first(where: { $0.id == card.accountID }) {
                                Text(account.pickerLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12, weight: .medium))
                        .accessibilityLabel(title(id))
                    Spacer(minLength: 4)
                    Button { store.moveDashboardTile(id, offset: -1, includingHidden: true) } label: { Image(systemName: "chevron.up").frame(width: 26, height: 26) }
                        .buttonStyle(QuietButtonStyle()).disabled(index == 0).accessibilityLabel("Move " + title(id) + " earlier")
                    Button { store.moveDashboardTile(id, offset: 1, includingHidden: true) } label: { Image(systemName: "chevron.down").frame(width: 26, height: 26) }
                        .buttonStyle(QuietButtonStyle()).disabled(index == ids.count - 1).accessibilityLabel("Move " + title(id) + " later")
                    if let insight = store.menuPreferences.dashboardLayout.insights.first(where: { $0.tileID == id }) {
                        Button { store.removeInsight(insight.id) } label: { Image(systemName: "minus.circle").frame(width: 26, height: 26) }
                            .buttonStyle(QuietButtonStyle()).accessibilityLabel("Remove " + title(id))
                    } else { Color.clear.frame(width: 26, height: 26) }
                }.padding(.vertical, 9)
                Divider().opacity(0.5)
            }
        }.padding(4)
    }
}

private struct InsightThumbnail: View {
    let kind: DashboardInsightKind
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            switch kind {
            case .usageCalendar:
                for col in 0..<24 { for row in 0..<5 {
                    let cell = CGRect(x: CGFloat(col) * size.width / 24, y: CGFloat(row) * 12, width: max(2,size.width / 24 - 3), height: 9)
                    context.fill(Path(roundedRect:cell,cornerRadius:2),with:.color(tint.opacity(0.10 + Double((col*7+row*11)%10)/12)))
                } }
            case .limitPressure:
                for index in 0..<2 {
                    let side: CGFloat = 57, x = size.width / 2 - 65 + CGFloat(index) * 73
                    let ring = Path(ellipseIn:CGRect(x:x,y:3,width:side,height:side))
                    context.stroke(ring,with:.color(tint.opacity(0.10)),lineWidth:6)
                    let amount = index == 0 ? 0.72 : 0.4
                    context.stroke(ring.trimmedPath(from:0,to:amount),with:.color(index == 0 ? tint : .purple),style:StrokeStyle(lineWidth:6,lineCap:.round))
                }
            case .unusedAllowance:
                for index in 0..<9 {
                    let width = size.width / 11, height = CGFloat([26,44,18,35,50,28,42,21,32][index])
                    let bar = Path(roundedRect:CGRect(x:CGFloat(index)*size.width/9,y:size.height-height,width:width,height:height),cornerRadius:4)
                    context.fill(bar,with:.linearGradient(Gradient(colors:[tint.opacity(0.9),tint.opacity(0.2)]),startPoint:CGPoint(x:0,y:0),endPoint:CGPoint(x:0,y:size.height)))
                }
            default:
                var line = Path();line.move(to:CGPoint(x:0,y:size.height*0.75))
                let values: [CGFloat] = kind == .creditRunway ? [0.30,0.38,0.32,0.49,0.56,0.60,0.68] : [0.70,0.37,0.51,0.28,0.38,0.17,0.24]
                var previous = CGPoint(x:0,y:size.height*0.75)
                for (index,value) in values.enumerated() {
                    let next = CGPoint(x:CGFloat(index+1)*size.width/CGFloat(values.count),y:value*size.height)
                    line.addCurve(to:next,control1:CGPoint(x:previous.x+(next.x-previous.x)*0.5,y:previous.y),control2:CGPoint(x:next.x-(next.x-previous.x)*0.5,y:next.y));previous=next
                }
                var fill = line;fill.addLine(to:CGPoint(x:size.width,y:size.height));fill.addLine(to:CGPoint(x:0,y:size.height));fill.closeSubpath()
                context.fill(fill,with:.linearGradient(Gradient(colors:[tint.opacity(0.45),tint.opacity(0.01)]),startPoint:rect.origin,endPoint:CGPoint(x:0,y:size.height)))
                context.stroke(line,with:.color(tint.opacity(0.12)),style:StrokeStyle(lineWidth:7,lineCap:.round))
                context.stroke(line,with:.color(tint),style:StrokeStyle(lineWidth:2,lineCap:.round))
            }
        }
    }
}

struct DashboardInsightCard: View {
    @ObservedObject var store: AppStore
    let card: DashboardInsight
    let tileOrder: [String]
    private var account: Account? { store.accounts.first { $0.id == card.accountID } }
    private var tint: Color { insightTint(card.kind, account: account) }
    var body: some View {
        SettingsCard(inset: 16, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: card.kind.symbol).foregroundStyle(tint).font(.system(size: 13, weight: .medium))
                    Text(card.kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                    Spacer(minLength: 1)
                    options.frame(width: 25)
                    DashboardCollapseButton(collapsed: card.collapsed, item: card.kind.title.lowercased()) { store.updateInsight(card.id) { $0.collapsed.toggle() } }
                }
                if card.collapsed {
                    Text(account.map(insightAccountTitle) ?? "Choose an account").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    controls
                    if let account, card.kind.supports(account.kind) {
                        content(account)
                        if store.connectionState(account).saved || store.needsSignIn(account) {
                            Label("Saved readings · estimates paused", systemImage: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    } else {
                        InsightEmpty(title: "Choose an account", detail: "Select a compatible account above. A removed account is never replaced automatically.", symbol: "person.crop.circle")
                    }
                }
            }
        }.environment(\.calendar, HistoryTrends.calendar).environment(\.timeZone, HistoryTrends.calendar.timeZone)
    }
    private var controls: some View {
        HStack(spacing: 8) {
            AppDropdown(account.map(insightAccountTitle) ?? "Choose account", symbol: "person.crop.circle", accent: tint, menuTitle: "Account for " + card.kind.title.lowercased()) {
                for account in store.accounts.filter({ card.kind.supports($0.kind) }) {
                    AppDropdownItem(account.pickerLabel, symbol: "person.crop.circle", selected: card.accountID == account.id) { store.setInsightAccount(card.id, accountID: account.id) }
                }
            }.accessibilityLabel("Account for " + card.kind.title.lowercased())
            if card.kind.periods.count > 1 {
                AppDropdown(card.period.title, accent: tint, menuTitle: "Time period") {
                    for period in card.kind.periods { AppDropdownItem(period.title, selected: card.period == period) { store.updateInsight(card.id) { $0.period = period } } }
                }.frame(width: 100).accessibilityLabel("Period for " + card.kind.title.lowercased())
            } else { Text("This cycle").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
        }
    }
    private var options: some View {
        AppDropdown("", symbol: "ellipsis", accent: tint, showsChevron: false, menuTitle: card.kind.title) {
            for style in card.kind.charts {
                AppDropdownItem(style.title, symbol: style.symbol, selected: card.chart == style) { store.updateInsight(card.id) { $0.chart = style } }
            }
            AppDropdownItem.separator
            for size in InsightSize.allCases {
                AppDropdownItem(size.title + " width", symbol: size == .compact ? "rectangle" : size == .wide ? "rectangle.split.2x1" : "rectangle.expand.horizontal", selected: card.size == size) { store.updateInsight(card.id) { $0.size = size } }
            }
            if [.burnRate, .usageCalendar].contains(card.kind), account?.kind.isAPI == false {
                AppDropdownItem.separator
                AppDropdownItem("Weekly allowance", selected: card.metric == .weekly) { store.updateInsight(card.id) { $0.metric = .weekly } }
                AppDropdownItem("5-hour allowance", selected: card.metric == .session) { store.updateInsight(card.id) { $0.metric = .session } }
            }
            AppDropdownItem.separator
            AppDropdownItem("Move earlier", symbol: "arrow.up", enabled: tileOrder.first != card.tileID) { store.moveDashboardTile(card.tileID, offset: -1, within: tileOrder) }
            AppDropdownItem("Move later", symbol: "arrow.down", enabled: tileOrder.last != card.tileID) { store.moveDashboardTile(card.tileID, offset: 1, within: tileOrder) }
            AppDropdownItem("Hide view", symbol: "eye.slash") { store.setDashboardTileHidden(card.tileID, hidden: true) }
            AppDropdownItem("Remove view", symbol: "minus.circle", destructive: true) { store.removeInsight(card.id) }
        }.accessibilityLabel("Options for " + card.kind.title.lowercased())
    }
    @ViewBuilder private func content(_ account: Account) -> some View {
        let points = store.history(for: account), days = store.usageDays[account.id] ?? []
        let snapshot = store.snapshots[account.id], connection = store.connectionState(account)
        let fresh = !connection.saved && !connection.needsAction && !store.needsSignIn(account)
        switch card.kind {
        case .weeklyPace:
            WeeklyPaceInsight(data: InsightAnalytics.weeklyPace(points: points, snapshot: snapshot, kind: account.kind, fresh: fresh, now: store.now), unlimited: snapshot?.unlimited == true, fresh: fresh, style: card.chart, tint: tint, now: store.now)
        case .unusedAllowance:
            UnusedAllowanceInsight(records: (store.resetCycles[account.id] ?? []).filter { $0.resetAt >= store.now.addingTimeInterval(-card.period.seconds) }, style: card.chart, tint: tint, now: store.now)
        case .limitPressure:
            LimitPressureInsight(points: points, snapshot: snapshot, kind: account.kind, period: card.period, style: card.chart, tint: tint, now: store.now)
        case .burnRate:
            BurnRateInsight(buckets: InsightAnalytics.rates(points, kind: account.kind, metric: card.metric, since: store.now.addingTimeInterval(-card.period.seconds), now: store.now, bucketHours: card.period == .week ? 6 : 1), bucketHours: card.period == .week ? 6 : 1, money: account.kind.isAPI, session: card.metric == .session, style: card.chart, tint: tint, now: store.now, since: store.now.addingTimeInterval(-card.period.seconds))
        case .usageCalendar:
            UsageCalendarInsight(data: InsightAnalytics.calendar(days: days, kind: account.kind, metric: card.metric, count: Int(card.period.seconds / 86400), now: store.now), money: account.kind.isAPI, session: card.metric == .session, style: card.chart, tint: tint, now: store.now)
        case .creditRunway:
            CreditRunwayInsight(data: InsightAnalytics.creditRunway(days: days, snapshot: snapshot, kind: account.kind, periodDays: Int(card.period.seconds / 86400), fresh: fresh, now: store.now), days: days, points: points, kind: account.kind, period: card.period, style: card.chart, tint: tint, now: store.now)
        }
    }
}

private struct InsightEmpty: View {
    let title: String
    let detail: String
    var symbol = "chart.xyaxis.line"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 165, alignment: .leading)
    }
}
private struct InsightMetricHeading: View {
    let value: String
    let caption: String
    var detail: String? = nil
    var tint: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).multilineTextAlignment(.trailing).lineLimit(2) }
        }
    }
}
private struct InsightPlotStyle: ViewModifier {
    var dates = false
    func body(content: Content) -> some View {
        content.chartLegend(.hidden)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: dates ? .dateTime.month(.abbreviated).day() : .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                    .font(.system(size: 9)).foregroundStyle(Color.secondary)
            } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2,4])).foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.secondary)
            } }
            .frame(height: 112).padding(.top, 3)
    }
}
private func insightFill(_ tint: Color) -> LinearGradient {
    LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.13), tint.opacity(0.015)], startPoint: .top, endPoint: .bottom)
}
private func insightBarFill(_ tint: Color) -> LinearGradient {
    LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.35)], startPoint: .top, endPoint: .bottom)
}
private func insightAccountTitle(_ account: Account) -> String {
    account.name.localizedCaseInsensitiveContains(account.kind.provider.title) ? account.name : account.name + " · " + account.kind.provider.title
}
private func insightPercent(_ value: Double) -> String { "\(Int(floor(min(100,max(0,value)))))%" }
private func insightMoney(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
private func insightDate(_ date: Date) -> String { date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: HistoryTrends.calendar.timeZone)) }

private struct WeeklyPaceInsight: View {
    let data: WeeklyPace?
    let unlimited: Bool
    let fresh: Bool
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    var body: some View {
        if let data {
            VStack(alignment: .leading, spacing: 10) {
                InsightMetricHeading(value: data.remaining == 0 ? "Allowance empty" : data.estimatedExhaustion != nil ? "May run out" : data.estimatedRemaining.map { "≈" + insightPercent($0) } ?? insightPercent(data.remaining),
                    caption: data.estimatedRemaining != nil ? "Estimated allowance at reset" : "Weekly allowance remaining", detail: "Resets " + data.resetAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()), tint: tint)
                Chart {
                    RuleMark(y: .value("Even pace", 0)).foregroundStyle(.clear)
                    ForEach(data.points) { point in
                        if style == .area { AreaMark(x: .value("Time",point.timestamp), y: .value("Remaining",point.remaining), series: .value("Segment",point.segment)).interpolationMethod(.monotone).foregroundStyle(insightFill(tint)) }
                        LineMark(x: .value("Time",point.timestamp), y: .value("Remaining",point.remaining), series: .value("Line",point.segment)).interpolationMethod(.monotone).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round,lineJoin:.round))
                    }
                    ForEach([data.cycleStart,data.resetAt],id:\.self) { date in
                        LineMark(x:.value("Time",date),y:.value("Even pace",date == data.cycleStart ? 100 : 0),series:.value("Pace","even")).foregroundStyle(Color.secondary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth:1,dash:[3,5]))
                    }
                    if let remaining = data.estimatedRemaining {
                        ForEach([data.observedAt,data.resetAt],id:\.self) { date in
                            LineMark(x:.value("Time",date),y:.value("Estimate",date == data.observedAt ? data.remaining : remaining),series:.value("Forecast","forecast")).foregroundStyle(tint.opacity(0.6)).lineStyle(StrokeStyle(lineWidth:1.7,dash:[4,4]))
                        }
                    }
                    PointMark(x:.value("Time",data.observedAt),y:.value("Remaining",data.remaining)).foregroundStyle(tint).symbolSize(22)
                }.chartXScale(domain:data.cycleStart...data.resetAt).chartYScale(domain:0...100).modifier(InsightPlotStyle(dates:true))
                    .accessibilityLabel("Weekly remaining allowance. Dashed lines show even pace and, when available, an estimate. Gaps are unmeasured.")
                HStack {
                    Text(data.pointsPerDay.map { String(format:"%.1f pts/day observed",$0) } ?? (fresh ? "Forecast needs 6 measured hours" : "Awaiting a current reading"))
                    Spacer(minLength:0)
                    Text(data.estimatedRemaining != nil ? "UTC chart · estimate" : "UTC · dashed = even pace")
                }.font(.system(size:9)).foregroundStyle(.secondary)
            }
        } else { InsightEmpty(title: unlimited ? "Unlimited plan" : "No weekly limit reported", detail: unlimited ? "This account does not report a percentage allowance to forecast." : "A current weekly allowance and reset time are needed for this view.") }
    }
}

private struct UnusedAllowanceInsight: View {
    let records: [ResetCycle]
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    private struct CyclePoint: Identifiable {
        var id: Date { cycle.resetAt }
        let cycle: ResetCycle
        let segment: Int
    }
    private var chartRecords: [CyclePoint] {
        var segment = 0
        return records.enumerated().map { index, cycle in
            if index > 0, cycle.resetAt.timeIntervalSince(records[index - 1].resetAt) > 8 * 86400 { segment += 1 }
            return CyclePoint(cycle: cycle, segment: segment)
        }
    }
    var body: some View {
        if let latest = records.last {
            VStack(alignment: .leading, spacing: 10) {
                InsightMetricHeading(value: insightPercent(latest.remainingPercent),caption:"Last recorded before the latest reset",detail:"\(records.count) recorded cycles",tint:tint)
                Chart(chartRecords) { item in
                    let record = item.cycle
                    if style == .bars {
                        RectangleMark(xStart:.value("Start",record.resetAt.addingTimeInterval(-2*86400)),xEnd:.value("End",record.resetAt.addingTimeInterval(2*86400)),yStart:.value("Baseline",0),yEnd:.value("Last seen remaining",record.remainingPercent)).foregroundStyle(insightBarFill(tint)).cornerRadius(4)
                            .accessibilityLabel("Reset " + insightDate(record.resetAt)).accessibilityValue(insightPercent(record.remainingPercent) + " last observed before reset")
                        if record.remainingPercent == 0 { PointMark(x:.value("Reset",record.resetAt),y:.value("Remaining",0)).foregroundStyle(tint).symbolSize(12) }
                    } else {
                        LineMark(x:.value("Reset",record.resetAt),y:.value("Last seen remaining",record.remainingPercent),series:.value("Recorded cycles",item.segment)).interpolationMethod(.monotone).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round))
                        PointMark(x:.value("Reset",record.resetAt),y:.value("Last seen remaining",record.remainingPercent)).foregroundStyle(tint).symbolSize(18)
                    }
                }.chartYScale(domain:0...100).modifier(InsightPlotStyle(dates:true))
                    .accessibilityLabel("Last observed remaining allowance before weekly resets. These are closing readings, not exact unused amounts.")
                Text("Last seen \(max(1,Int(latest.observationGap/60)))m before reset · allowance may have changed afterward.")
                    .font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        } else { InsightEmpty(title:"Waiting for a recorded reset",detail:"Closing readings are saved when a weekly reset is observed. Long gaps are left out; past cycles are never invented.",symbol:"arrow.counterclockwise.circle") }
    }
}

private struct LimitPressureInsight: View {
    let points: [UsageHistoryPoint]
    let snapshot: Snapshot?
    let kind: ConnectionKind
    let period: InsightPeriod
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    private var weekly: Double? { snapshot?.primaryWeeklyWindow(for:kind).flatMap { $0.durationMinutes == 10080 ? $0.remainingPercent : nil } }
    private var session: Double? { snapshot?.sessionWindow(for:kind)?.remainingPercent }
    private var samples: [UsageHistoryPoint] { points.filter { $0.timestamp >= now.addingTimeInterval(-period.seconds) && $0.timestamp <= now } }
    private var observed: [Double] { samples.compactMap { point in
        let values = [ResetCycles.isWeekly(point) ? point.remainingPercent : nil,point.sessionRemainingPercent].compactMap { $0 }
        return values.min()
    } }
    var body: some View {
        if weekly != nil || session != nil {
            VStack(alignment:.leading,spacing:10) {
                let limiting = session == nil ? "Weekly limit only" : weekly == nil ? "5-hour limit only" : weekly! <= session! ? "Weekly is the tighter limit" : "5-hour is the tighter limit"
                Text(limiting).font(.system(size:13,weight:.medium))
                if style == .rings {
                    HStack(spacing:22) {
                        if let weekly { pressureRing("Weekly",value:weekly,color:tint) }
                        if let session { pressureRing("5-hour",value:session,color:.purple) }
                    }.frame(maxWidth:.infinity).frame(height:126)
                } else {
                    let week = InsightAnalytics.allowanceSeries(samples,kind:kind,session:false,since:now.addingTimeInterval(-period.seconds),now:now)
                    let hour = InsightAnalytics.allowanceSeries(samples,kind:kind,session:true,since:now.addingTimeInterval(-period.seconds),now:now)
                    Chart {
                        ForEach(week) { point in LineMark(x:.value("Time",point.timestamp),y:.value("Weekly",point.remaining),series:.value("Limit","w\(point.segment)")).interpolationMethod(.monotone).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round)) }
                        ForEach(hour) { point in LineMark(x:.value("Time",point.timestamp),y:.value("5-hour",point.remaining),series:.value("Limit","h\(point.segment)")).interpolationMethod(.monotone).foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round)) }
                    }.chartYScale(domain:0...100).modifier(InsightPlotStyle(dates:period == .week))
                    HStack { if let weekly { Text("Weekly " + insightPercent(weekly)).foregroundStyle(tint) }; if let session { Text("5h " + insightPercent(session)).foregroundStyle(.purple) } }.font(.system(size:10,weight:.medium))
                }
                Text(observed.isEmpty ? "No recent measured readings" : "\(observed.filter { $0 <= 10 }.count) of \(observed.count) readings at 10% or less")
                    .font(.system(size:10)).foregroundStyle(.secondary)
                if session == nil { Text("This account does not report a 5-hour limit.").font(.system(size:9)).foregroundStyle(.secondary) }
            }
        } else { InsightEmpty(title:snapshot?.unlimited == true ? "Unlimited plan" : "Weekly or 5-hour limit not reported",detail:"This view compares weekly and 5-hour allowances when the provider reports them.",symbol:"gauge.with.dots.needle.67percent") }
    }
    private func pressureRing(_ title:String,value:Double,color:Color) -> some View {
        VStack(spacing:7) {
            ZStack {
                Circle().stroke(color.opacity(0.10),lineWidth:8)
                Circle().trim(from:0,to:min(1,max(0,value/100))).stroke(AngularGradient(colors:[color.opacity(0.35),color],center:.center),style:StrokeStyle(lineWidth:8,lineCap:.round)).rotationEffect(.degrees(-90))
                Text(insightPercent(value)).font(.system(size:20,weight:.semibold,design:.rounded)).monospacedDigit()
            }.frame(width:92,height:92)
            Text(title + " left").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
        }.accessibilityElement(children:.ignore).accessibilityLabel(title + ": " + insightPercent(value) + " remaining")
    }
}

private struct BurnRateInsight: View {
    let buckets: [InsightRateBucket]
    let bucketHours: Int
    let money: Bool
    let session: Bool
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    let since: Date
    var body: some View {
        if let peak = buckets.max(by:{ $0.ratePerHour < $1.ratePerHour }) {
            VStack(alignment:.leading,spacing:10) {
                InsightMetricHeading(value:money ? insightMoney(peak.ratePerHour) : String(format:"%.1f pts",peak.ratePerHour),caption:"Peak per measured hour",detail:money ? "USD" : session ? "5-hour allowance" : "Weekly allowance",tint:tint)
                Chart(buckets) { bucket in
                    if style == .bars {
                        RectangleMark(xStart:.value("Start",bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start)*0.12)),xEnd:.value("End",bucket.end.addingTimeInterval(-bucket.end.timeIntervalSince(bucket.start)*0.12)),yStart:.value("Baseline",0),yEnd:.value("Rate",bucket.ratePerHour)).foregroundStyle(insightBarFill(tint)).cornerRadius(4)
                        if bucket.ratePerHour == 0 { PointMark(x:.value("Time",bucket.midpoint),y:.value("Rate",0)).foregroundStyle(tint).symbolSize(12) }
                    }
                    else {
                        if style == .area { AreaMark(x:.value("Time",bucket.midpoint),y:.value("Rate",bucket.ratePerHour),series:.value("Segment",bucket.segment)).interpolationMethod(.monotone).foregroundStyle(insightFill(tint)) }
                        LineMark(x:.value("Time",bucket.midpoint),y:.value("Rate",bucket.ratePerHour),series:.value("Line",bucket.segment)).interpolationMethod(.monotone).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round,lineJoin:.round))
                    }
                }.chartXScale(domain:since...now).chartYScale(domain:0...max(1,peak.ratePerHour*1.15)).modifier(InsightPlotStyle(dates:now.timeIntervalSince(since)>86400))
                Text("\(bucketHours)h buckets · measured intervals only · gaps excluded")
                    .font(.system(size:9)).foregroundStyle(.secondary)
            }
        } else { InsightEmpty(title:"Not enough measured usage yet",detail:"Recent changes become an hourly consumption rate. Resets, top-ups and connection gaps are excluded.",symbol:"waveform.path") }
    }
}

private struct UsageCalendarInsight: View {
    let data: InsightCalendar
    let money: Bool
    let session: Bool
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    var body: some View {
        if data.measuredDays > 0 {
            VStack(alignment:.leading,spacing:10) {
                InsightMetricHeading(value:"\(data.activeDays) active days",caption:"\(data.measuredDays) days with readings",detail:"\(data.longestStreak)-day longest streak",tint:tint)
                if style == .calendar { InsightCalendarGrid(data:data,tint:tint,money:money).frame(height:115) }
                else {
                    let grouped = calendarBars
                    Chart(grouped) { day in
                        let span = Double(data.days.count > 60 ? 7 : 1) * 86400
                        RectangleMark(xStart:.value("Start",day.date.addingTimeInterval(span*0.14)),xEnd:.value("End",day.date.addingTimeInterval(span*0.86)),yStart:.value("Baseline",0),yEnd:.value("Consumed",day.amount ?? 0)).foregroundStyle(insightBarFill(tint)).cornerRadius(3)
                        if day.amount == 0 { PointMark(x:.value("Day",day.date.addingTimeInterval(span/2)),y:.value("Consumed",0)).foregroundStyle(tint).symbolSize(10) }
                    }.modifier(InsightPlotStyle(dates:true))
                }
                HStack {
                    Text(style == .bars && data.days.count > 60 ? "Weekly totals · UTC" : money ? "Observed USD · UTC days" : "Observed \(session ? "5-hour" : "weekly") allowance · UTC days")
                    Spacer(minLength:0);Text(style == .calendar ? "Outlined = no reading" : "Gaps = no reading")
                }.font(.system(size:9)).foregroundStyle(.secondary)
            }
        } else { InsightEmpty(title:"Your calendar starts with readings",detail:"Days light up when consumption is measured. An unmeasured day stays outlined, rather than appearing as zero.",symbol:"calendar") }
    }
    private var calendarBars: [InsightCalendarDay] {
        guard data.days.count > 60 else { return data.days.filter { $0.amount != nil } }
        return stride(from:0,to:data.days.count,by:7).compactMap { index in
            let days = data.days[index..<min(index+7,data.days.count)], measured = days.filter { $0.amount != nil }
            guard !measured.isEmpty else { return nil }
            return InsightCalendarDay(date:days.first!.date,amount:measured.reduce(0) { $0 + ($1.amount ?? 0) },measuredSeconds:measured.reduce(0) { $0 + $1.measuredSeconds })
        }
    }
}

private struct InsightCalendarGrid: View {
    let data: InsightCalendar
    let tint: Color
    let money: Bool
    @InsightState private var hovered: Int?
    private var columns: Int { max(1,Int(ceil(Double(data.days.count)/7))) }
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            GeometryReader { geometry in
                Canvas { context,size in
                    let step = min(15,size.width/CGFloat(columns)), height = min(11,(size.height-2)/7), width = max(2,step-2)
                    let maximum = max(0.001,data.days.compactMap(\.amount).max() ?? 1)
                    for (index,day) in data.days.enumerated() {
                        let rect = CGRect(x:CGFloat(index/7)*step,y:CGFloat(index%7)*(height+2),width:width,height:height)
                        let path = Path(roundedRect:rect,cornerRadius:min(2,width/3))
                        if let amount = day.amount {
                            context.fill(path,with:.color(tint.opacity(amount == 0 ? 0.09 : 0.22+0.78*sqrt(amount/maximum))))
                        } else { context.stroke(path,with:.color(Color.primary.opacity(0.13)),lineWidth:0.65) }
                        if hovered == index { context.stroke(path,with:.color(tint),lineWidth:1.2) }
                    }
                }.onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let step = min(15,geometry.size.width/CGFloat(columns)), height = min(11,(geometry.size.height-2)/7)+2
                        let index = Int(max(0,point.x)/max(1,step))*7+Int(max(0,point.y)/max(1,height))
                        let next = data.days.indices.contains(index) && point.x < CGFloat(columns)*step ? index : nil
                        if hovered != next { hovered = next }
                    case .ended: hovered = nil
                    }
                }
            }
            Text(hovered.flatMap { index -> String? in
                guard data.days.indices.contains(index) else { return nil };let day=data.days[index]
                return insightDate(day.date) + " · " + (day.amount.map { money ? insightMoney($0) + " observed" : String(format:"%.1f points observed",$0) } ?? "No measured reading")
            } ?? "Less  ▪ ▪ ▪ ▪ ▪  More")
                .font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children:.ignore).accessibilityLabel("Usage calendar. \(data.activeDays) active days, \(data.measuredDays) measured days, longest observed streak \(data.longestStreak) days. Unmeasured days are outlined.")
    }
}

private struct CreditRunwayInsight: View {
    let data: CreditRunway?
    let days: [UsageDay]
    let points: [UsageHistoryPoint]
    let kind: ConnectionKind
    let period: InsightPeriod
    let style: InsightChartStyle
    let tint: Color
    let now: Date
    var body: some View {
        if let data {
            VStack(alignment:.leading,spacing:10) {
                InsightMetricHeading(value:data.balance <= 0 ? "Credits empty" : data.estimatedDaysLeft.map { $0 > 365 ? "Over a year" : $0 < 1 ? "Under a day" : "≈\(Int($0)) days" } ?? insightMoney(data.balance),caption:data.balance <= 0 ? insightMoney(data.balance) + " balance · USD" : data.estimatedDaysLeft != nil ? "Estimated credit runway" : "Credit balance · USD",detail:data.estimatedDailySpending.map { insightMoney($0) + "/day observed" } ?? "Needs 3 measured days",tint:tint)
                if style == .bars {
                    let recorded = days.filter { $0.day >= now.addingTimeInterval(-period.seconds) && $0.money != nil }
                    Chart(recorded) { day in
                        RectangleMark(xStart:.value("Start",day.day.addingTimeInterval(86400*0.16)),xEnd:.value("End",day.day.addingTimeInterval(86400*0.84)),yStart:.value("Baseline",0),yEnd:.value("USD",day.money?.amount ?? 0)).foregroundStyle(insightBarFill(tint)).cornerRadius(4)
                        if day.money?.amount == 0 { PointMark(x:.value("Day",day.day.addingTimeInterval(43200)),y:.value("USD",0)).foregroundStyle(tint).symbolSize(10) }
                    }
                        .modifier(InsightPlotStyle(dates:true))
                } else {
                    let history = HistorySeries.plotSamples(HistorySeries.samples(points.filter { $0.timestamp >= now.addingTimeInterval(-period.seconds) && $0.timestamp <= now },kind:kind),maximum:160)
                    let future = data.estimatedDailySpending != nil && data.balance > 0 ? min(14,max(0,data.estimatedDaysLeft ?? 0)) : 0
                    let futureEnd = now.addingTimeInterval(future * 86400)
                    Chart {
                        ForEach(history) { point in
                            if style == .area { AreaMark(x:.value("Time",point.timestamp),y:.value("Balance",point.value),series:.value("Segment",point.segment)).foregroundStyle(insightFill(tint)).interpolationMethod(.monotone) }
                            LineMark(x:.value("Time",point.timestamp),y:.value("Balance",point.value),series:.value("Line",point.segment)).foregroundStyle(tint).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth:2.2,lineCap:.round))
                        }
                        if let daily = data.estimatedDailySpending, futureEnd > now {
                            ForEach([now,futureEnd],id:\.self) { date in
                                LineMark(x:.value("Time",date),y:.value("Projected balance",date == now ? data.balance : max(0,data.balance-daily*future)),series:.value("Estimate","forecast")).foregroundStyle(tint.opacity(0.65)).lineStyle(StrokeStyle(lineWidth:1.7,dash:[4,4]))
                            }
                        }
                    }.chartXScale(domain:now.addingTimeInterval(-period.seconds)...futureEnd).chartYScale(domain:0...max(1,max(data.balance,history.map(\.value).max() ?? data.balance)*1.1)).modifier(InsightPlotStyle(dates:true))
                }
                Text(data.estimatedDaysLeft != nil ? "\(data.measuredDays) measured UTC days · \(style == .bars ? "observed USD" : "dashed = estimate") · top-ups excluded" : "Estimates need 3 days and 12 hours of measured spending.")
                    .font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        } else { InsightEmpty(title:"Waiting for a credit balance",detail:"This view uses an API credit account with a reported balance. Subscription percentages are never converted into dollars.",symbol:"creditcard") }
    }
}
