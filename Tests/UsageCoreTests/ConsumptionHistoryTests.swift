import Foundation
import Testing
@testable import UsageCore

private let usageStart = HistoryTrends.calendar.startOfDay(for: Date(timeIntervalSince1970: 1800000000))
private func usagePoint(_ seconds: Double, _ remaining: Double, reset: Double = 100000, session: Double? = nil) -> UsageHistoryPoint {
    var p = UsageHistoryPoint(timestamp: usageStart.addingTimeInterval(seconds), remainingPercent: remaining, windowID: "week.all models", resetsAt: usageStart.addingTimeInterval(reset))
    p.sessionRemainingPercent = session
    p.sessionResetsAt = usageStart.addingTimeInterval(5000)
    return p
}

@Test func consumptionExcludesRefillsResetsAndMissingIntervals() {
    let points = [usagePoint(0,80),usagePoint(300,70),usagePoint(600,100,reset:200000),usagePoint(900,96,reset:200000),usagePoint(5000,40,reset:200000)]
    let days = ConsumptionHistory.rebuild(points, kind: .claudeCode)
    #expect(days.count == 1)
    #expect(days[0].weekly?.amount == 14)
    #expect(days[0].weekly?.seconds == 600)
}

@Test func dailyConsumptionSplitsMidnightAndSeparatesQuotaWindows() {
    let points = [usagePoint(86300,80,session:90),usagePoint(86500,70,session:60)]
    let days = ConsumptionHistory.rebuild(points, kind: .claudeCode)
    #expect(days.count == 2)
    #expect(days.allSatisfy { $0.weekly?.amount == 5 && $0.session?.amount == 15 })
    #expect(days.allSatisfy { $0.weekly?.seconds == 100 })
}

@Test func measuredZeroIsNotMissingAndLongViewsDoNotBridgeGaps() {
    let days = [UsageDay(day: usageStart, weekly: .init(amount:0,seconds:86400)),
                UsageDay(day: usageStart.addingTimeInterval(14*86400), weekly: .init(amount:12,seconds:1000))]
    let buckets = ConsumptionHistory.buckets(days, kind:.claudeCode, session:false, since:usageStart, now:usageStart.addingTimeInterval(21*86400), weekly:true)
    #expect(buckets.count == 2)
    #expect(buckets[0].amount == 0)
    #expect(buckets[1].segment != buckets[0].segment)
    #expect(buckets[1].trend == 12)
    #expect(buckets.allSatisfy { $0.partial })
}

@Test func monthlyRolloversAndCreditTopupsAreNotConsumption() {
    let first = UsageHistoryPoint(timestamp:usageStart, balanceUSD:10,costUSD:20)
    let topup = UsageHistoryPoint(timestamp:usageStart.addingTimeInterval(300),balanceUSD:50,costUSD:2)
    #expect(ConsumptionHistory.rebuild([first,topup],kind:.openRouter).isEmpty)
    #expect(ConsumptionHistory.rebuild([first,topup],kind:.openAIAPI).isEmpty)
    let used = UsageHistoryPoint(timestamp:usageStart.addingTimeInterval(600),balanceUSD:45,costUSD:3)
    #expect(ConsumptionHistory.rebuild([topup,used],kind:.openRouter).first?.money?.amount == 5)
    #expect(ConsumptionHistory.rebuild([topup,used],kind:.openAIAPI).first?.money?.amount == 1)
}

@Test func consumptionSummariesSurviveCompactionAndReloadWithoutDoubleCounting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    var account = Account(name:"Fixture",kind:.claudeCode); account.expectedIdentity="fixture@example.com"
    func snapshot(_ offset:Double,_ remaining:Double) throws -> Snapshot {
        Snapshot(observedAt:usageStart.addingTimeInterval(offset),windows:[try QuotaWindow(id:"week.all models",label:"Week",usedPercent:100-remaining,resetsAt:usageStart.addingTimeInterval(offset+86400),durationMinutes:10080)],identity:"fixture@example.com",source:"Fixture")
    }
    let cache = SnapshotCache(root:root)
    let first = try snapshot(0,80)
    var next = try snapshot(300,70)
    next.windows = first.windows
    next.windows[0].usedPercent = 30
    try cache.save(first,for:account)
    try cache.save(next,for:account)
    try cache.save(next,for:account)
    let later = try snapshot(30*86400,90)
    try cache.save(later,for:account)
    let days = try #require(SnapshotCache(root:root).loadUsage(accounts:[account],now:later.observedAt)[account.id])
    #expect(days.count == 1)
    #expect(days[0].weekly?.amount == 10)
    #expect(days[0].weekly?.seconds == 300)
    #expect(cache.loadHistory(accounts:[account],now:later.observedAt)[account.id]?.count == 2)
}

@Test func hourlyAPIReadingsAllowRefreshLatencyButExcludeOutages() {
    var first = UsageHistoryPoint(timestamp: usageStart, costUSD: 10)
    first.continuityInterval = 4500
    var next = UsageHistoryPoint(timestamp: usageStart.addingTimeInterval(3610), costUSD: 12)
    next.continuityInterval = 4500
    #expect(ConsumptionHistory.rebuild([first, next], kind: .openAIAPI).first?.money?.amount == 2)
    var late = UsageHistoryPoint(timestamp: usageStart.addingTimeInterval(7200), costUSD: 12)
    late.continuityInterval = 4500
    #expect(ConsumptionHistory.rebuild([first, late], kind: .openAIAPI).isEmpty)
}

@Test func codexWeeklyPrimaryUsesDurationAndMigratesUnambiguousLegacyHistory() {
    var a = UsageHistoryPoint(timestamp: usageStart, remainingPercent: 90, windowID: "codex.Primary", resetsAt: usageStart.addingTimeInterval(86400))
    var b = UsageHistoryPoint(timestamp: usageStart.addingTimeInterval(300), remainingPercent: 85, windowID: "codex.Primary", resetsAt: usageStart.addingTimeInterval(86400))
    #expect(ConsumptionHistory.rebuild([a,b], kind: .codex).first?.weekly?.amount == 5)
    a.windowDurationMinutes = 300; b.windowDurationMinutes = 300
    #expect(ConsumptionHistory.rebuild([a,b], kind: .codex).isEmpty)
    a.windowDurationMinutes = 10080; b.windowDurationMinutes = 10080
    #expect(ConsumptionHistory.rebuild([a,b], kind: .codex).first?.weekly?.amount == 5)
}
