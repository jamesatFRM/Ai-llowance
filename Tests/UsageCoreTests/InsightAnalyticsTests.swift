import Foundation
import Testing
@testable import UsageCore

private let insightNow = HistoryTrends.calendar.startOfDay(for: Date(timeIntervalSince1970: 1800000000)).addingTimeInterval(12 * 3600)
private func insightPoint(_ seconds: Double, remaining: Double = 80, reset: Date? = nil, session: Double? = nil) -> UsageHistoryPoint {
    var point = UsageHistoryPoint(timestamp: insightNow.addingTimeInterval(seconds), remainingPercent: remaining,
        windowID: "week.all models", resetsAt: reset ?? insightNow.addingTimeInterval(3 * 86400))
    point.windowDurationMinutes = 10080; point.sessionRemainingPercent = session
    point.sessionResetsAt = insightNow.addingTimeInterval(2 * 3600)
    return point
}

@Test func optionalInsightPreferencesDoNotChangeLegacyDashboards() throws {
    let preferences = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(preferences.dashboardLayout.insights.isEmpty)
    #expect(preferences.dashboardLayout.hidden.isEmpty)
    #expect(preferences.dashboardChartStyle == .mixed)
}

@Test func insightChoicesRoundTripWithoutMixingAccountsOrMetrics() throws {
    let account = UUID(); var preferences = MenuPreferences()
    var card = DashboardInsight(kind: .burnRate, accountID: account, chart: .bars, period: .hours, size: .full, metric: .session)
    card.collapsed = true
    preferences.dashboardLayout.insights = [card]
    preferences.dashboardLayout.hidden = [card.tileID]
    preferences.dashboardLayout.order = [card.tileID, "activity"]
    let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored == preferences)
    #expect(restored.dashboardLayout.insights[0].accountID == account)
    #expect(restored.dashboardLayout.insights[0].metric == .session)
}

@Test func futureInsightKindsAndUnsupportedChartChoicesCannotLockAccountSettings() throws {
    let known = UUID().uuidString, future = UUID().uuidString
    let raw = """
    {"dashboardLayout":{"insights":[{"id":"\(future)","kind":"futureView"},{"id":"\(known)","kind":"weeklyPace","chart":"rings","period":"year","size":"future"}],"order":["bad","activity","activity"],"hidden":["bad","activity"]}}
    """
    let preferences = try JSONDecoder().decode(MenuPreferences.self, from: Data(raw.utf8))
    let card = try #require(preferences.dashboardLayout.insights.first)
    #expect(preferences.dashboardLayout.insights.count == 1)
    #expect(card.chart == .area && card.period == .cycle && card.size == .wide)
    #expect(preferences.dashboardLayout.order == ["activity"])
    #expect(preferences.dashboardLayout.hidden == ["activity"])
}

@Test func layoutOrderingPreservesHiddenChoicesAndOmitsRemovedCards() {
    var layout = DashboardLayoutPreferences(); layout.hidden = ["activity"]
    let account = DashboardLayoutPreferences.accountTileID(UUID())
    layout.order = ["activity",account,"overview"]
    #expect(layout.arranged([account,"activity","overview"]) == [account,"overview"])
    #expect(layout.arranged([account,"activity","overview"],includingHidden:true) == ["activity",account,"overview"])
    #expect(layout.arranged([account,"overview"],includingHidden:true) == [account,"overview"])
}

@Test func insightSizesHonorRequestedWidthsAndStayWithinTheWindow() {
    let plan = DashboardGridPlan(width:1000,columns:3,items:[.init(heights:[100,100],minimumSpan:2),.init(heights:[100,100,100],minimumSpan:4)])
    #expect(plan.frames[0].span == 2)
    #expect(plan.frames[1].span == 3)
    #expect(plan.frames.allSatisfy { $0.x + $0.width <= 1000.01 })
}

@Test func ratesExcludeResetsRefillsGapsAndSessionMixups() {
    let reset = insightNow.addingTimeInterval(-600)
    let points = [insightPoint(-1500,remaining:80,reset:reset,session:90),insightPoint(-1200,remaining:75,reset:reset,session:80),
        insightPoint(-300,remaining:100,session:70),insightPoint(0,remaining:98,session:60)]
    let weekly = InsightAnalytics.intervals(points,kind:.claudeCode,since:insightNow.addingTimeInterval(-86400),now:insightNow)
    #expect(weekly.reduce(0) { $0 + $1.amount } == 7)
    let session = InsightAnalytics.intervals(points,kind:.claudeCode,metric:.session,since:insightNow.addingTimeInterval(-86400),now:insightNow)
    #expect(session.reduce(0) { $0 + $1.amount } == 30)
    let gap = [insightPoint(-7200,remaining:95),insightPoint(0,remaining:40)]
    #expect(InsightAnalytics.rates(gap,kind:.claudeCode,since:insightNow.addingTimeInterval(-86400),now:insightNow).isEmpty)
}

@Test func hourlyRatesKeepMeasuredZerosAndSeparateMissingHours() {
    let points = [insightPoint(-10800,remaining:90),insightPoint(-10500,remaining:90),insightPoint(-3600,remaining:80),insightPoint(-3300,remaining:78)]
    let rates = InsightAnalytics.rates(points,kind:.claudeCode,since:insightNow.addingTimeInterval(-14400),now:insightNow)
    #expect(rates.count == 2)
    #expect(rates[0].ratePerHour == 0)
    #expect(rates[1].ratePerHour == 24)
    #expect(rates[0].segment != rates[1].segment)
    #expect(rates.allSatisfy { $0.coverage < 1 })
}

@Test func weeklyForecastNeedsFreshMeasuredHistoryAndNeverCountsOldCycles() throws {
    let reset = insightNow.addingTimeInterval(3 * 86400)
    let points = (0...16).map { insightPoint(Double($0 - 16) * 1800,remaining:96-Double($0)*2,reset:reset) }
    let window = try QuotaWindow(id:"week.all models",label:"Weekly",usedPercent:36,resetsAt:reset,durationMinutes:10080)
    let snapshot = Snapshot(observedAt:insightNow,windows:[window],source:"Fixture")
    let pace = try #require(InsightAnalytics.weeklyPace(points:points,snapshot:snapshot,kind:.claudeCode,fresh:true,now:insightNow))
    #expect(pace.measuredSeconds == 8 * 3600)
    #expect(pace.pointsPerDay == 96)
    #expect(pace.estimatedRemaining == 0)
    #expect(pace.estimatedExhaustion == insightNow.addingTimeInterval(16 * 3600))
    let cached = try #require(InsightAnalytics.weeklyPace(points:points,snapshot:snapshot,kind:.claudeCode,fresh:false,now:insightNow))
    #expect(cached.estimatedRemaining == nil && cached.pointsPerDay == nil)
    var stale = snapshot; stale.observedAt = insightNow.addingTimeInterval(-3600)
    #expect(InsightAnalytics.weeklyPace(points:points,snapshot:stale,kind:.claudeCode,fresh:true,now:insightNow)?.estimatedRemaining == nil)
    var restricted = snapshot; restricted.providerRestricted = true
    #expect(InsightAnalytics.weeklyPace(points:points,snapshot:restricted,kind:.claudeCode,fresh:true,now:insightNow)?.estimatedRemaining == nil)
    #expect(InsightAnalytics.weeklyPace(points:Array(points.suffix(2)),snapshot:snapshot,kind:.claudeCode,fresh:true,now:insightNow)?.estimatedRemaining == nil)
    let otherCycle = points.map { var p = $0; p = insightPoint(p.timestamp.timeIntervalSince(insightNow),remaining:p.remainingPercent!,reset:reset.addingTimeInterval(-7*86400)); return p }
    #expect(InsightAnalytics.weeklyPace(points:otherCycle,snapshot:snapshot,kind:.claudeCode,fresh:true,now:insightNow)?.points.isEmpty == true)
}

@Test func sessionOnlyAndUnlimitedPlansDoNotGetInventedWeeklyForecasts() throws {
    let session = try QuotaWindow(id:"session",label:"5h",usedPercent:20,resetsAt:insightNow.addingTimeInterval(3600),durationMinutes:300)
    #expect(InsightAnalytics.weeklyPace(points:[],snapshot:Snapshot(observedAt:insightNow,windows:[session],source:"Fixture"),kind:.claudeCode,fresh:true,now:insightNow) == nil)
    #expect(InsightAnalytics.weeklyPace(points:[],snapshot:Snapshot(observedAt:insightNow,source:"Fixture",unlimited:true),kind:.copilot,fresh:true,now:insightNow) == nil)
}

@Test func calendarDistinguishesMeasuredZeroUnmeasuredAndActualActiveDays() {
    let today = HistoryTrends.calendar.startOfDay(for:insightNow)
    let days = [UsageDay(day:today.addingTimeInterval(-3*86400),weekly:.init(amount:5,seconds:86400)),
        UsageDay(day:today.addingTimeInterval(-2*86400),weekly:.init(amount:0,seconds:86400)),
        UsageDay(day:today,weekly:.init(amount:3,seconds:3600))]
    let calendar = InsightAnalytics.calendar(days:days,kind:.codex,count:4,now:insightNow)
    #expect(calendar.activeDays == 2 && calendar.measuredDays == 3 && calendar.longestStreak == 1)
    #expect(calendar.days[1].amount == 0 && calendar.days[2].amount == nil)
    #expect(calendar.busiestDay?.amount == 5)
}

@Test func creditRunwayRequiresSeveralMeasuredDaysAndNeverUsesSubscriptionPercentages() throws {
    let today = HistoryTrends.calendar.startOfDay(for:insightNow)
    let days = (1...3).map { UsageDay(day:today.addingTimeInterval(-Double($0)*86400),money:.init(amount:2,seconds:86400)) }
    let snapshot = Snapshot(observedAt:insightNow,source:"Fixture",balanceUSD:60)
    let runway = try #require(InsightAnalytics.creditRunway(days:days,snapshot:snapshot,kind:.vercelGateway,periodDays:14,fresh:true,now:insightNow))
    #expect(runway.estimatedDailySpending == 2 && runway.estimatedDaysLeft == 30)
    #expect(InsightAnalytics.creditRunway(days:days,snapshot:snapshot,kind:.claudeCode,periodDays:14,fresh:true,now:insightNow) == nil)
    #expect(InsightAnalytics.creditRunway(days:days,snapshot:snapshot,kind:.vercelGateway,periodDays:14,fresh:false,now:insightNow)?.estimatedDaysLeft == nil)
    #expect(InsightAnalytics.creditRunway(days:Array(days.prefix(2)),snapshot:snapshot,kind:.vercelGateway,periodDays:14,fresh:true,now:insightNow)?.estimatedDaysLeft == nil)
    var stale = snapshot; stale.observedAt = insightNow.addingTimeInterval(-3600)
    #expect(InsightAnalytics.creditRunway(days:days,snapshot:stale,kind:.vercelGateway,periodDays:14,fresh:true,now:insightNow)?.estimatedDaysLeft == nil)
    var restricted = snapshot; restricted.providerRestricted = true
    #expect(InsightAnalytics.creditRunway(days:days,snapshot:restricted,kind:.vercelGateway,periodDays:14,fresh:true,now:insightNow)?.estimatedDaysLeft == nil)
}

@Test func resetCycleSummariesKeepClosingObservationWithoutInventingResetPrecision() {
    let reset = insightNow.addingTimeInterval(-600)
    let previous = insightPoint(-900,remaining:33,reset:reset), current = insightPoint(0,remaining:100)
    let records = ResetCycles.append([],previous:previous,current:current,kind:.claudeCode)
    #expect(records.count == 1 && records[0].remainingPercent == 33 && records[0].observationGap == 300)
    #expect(ResetCycles.append(records,previous:previous,current:current,kind:.claudeCode).count == 1)
    #expect(ResetCycles.append([],previous:insightPoint(-2*86400,reset:reset),current:current,kind:.claudeCode).isEmpty)
    #expect(ResetCycles.append([],previous:previous,current:current,kind:.vercelGateway).isEmpty)
    var changed = current; changed.windowDurationMinutes = 300
    #expect(ResetCycles.append([],previous:previous,current:changed,kind:.claudeCode).isEmpty)
}

@Test func resetCycleHistorySurvivesCompactionReauthenticationAndReload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("InsightCycles-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    var account = Account(name:"Fixture",kind:.claudeCode);account.expectedIdentity="fixture@example.com"
    let reset = insightNow.addingTimeInterval(-600)
    func snapshot(_ date:Date,_ remaining:Double,_ next:Date) throws -> Snapshot {
        Snapshot(observedAt:date,windows:[try QuotaWindow(id:"week.all models",label:"Weekly",usedPercent:100-remaining,resetsAt:next,durationMinutes:10080)],identity:"fixture@example.com",source:"Fixture")
    }
    let cache = SnapshotCache(root:root)
    try cache.save(snapshot(insightNow.addingTimeInterval(-900),33,reset),for:account)
    try cache.save(snapshot(insightNow,100,insightNow.addingTimeInterval(3*86400)),for:account)
    try cache.save(snapshot(insightNow.addingTimeInterval(60*86400),90,insightNow.addingTimeInterval(63*86400)),for:account)
    try cache.invalidateSnapshot(account,now:insightNow.addingTimeInterval(60*86400))
    let state = cache.loadState(accounts:[account],now:insightNow.addingTimeInterval(60*86400))
    #expect(state.snapshots.isEmpty)
    #expect(state.resetCycles[account.id]?.count == 1)
    #expect(state.resetCycles[account.id]?.first?.remainingPercent == 33)
    #expect(state.history[account.id]?.count == 2)
    var otherAccount = account; otherAccount.expectedIdentity = "other@example.com"
    #expect(cache.loadState(accounts:[otherAccount],now:insightNow.addingTimeInterval(60*86400)).resetCycles[account.id] == nil)
}
