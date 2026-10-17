import Foundation
import Testing
@testable import UsageCore

private let usefulNow = Date(timeIntervalSince1970: 1_790_000_000)
private func usefulAccount(_ kind: ConnectionKind = .claudeCode, email: String = "person@example.com") -> Account {
    var account = Account(name: "Personal", kind: kind); account.expectedIdentity = email; return account
}
private func usefulReading(_ remaining: Double, at date: Date = usefulNow, reset: Date? = nil, identity: String = "person@example.com") throws -> Snapshot {
    Snapshot(observedAt: date, windows: [try QuotaWindow(id: "session", label: "Session", usedPercent: 100 - remaining,
                                                      resetsAt: reset ?? usefulNow.addingTimeInterval(7200), durationMinutes: 300)],
             identity: identity, source: "Fixture")
}

@Test func unlimitedMenuEntriesAreExplicitAndNeverHideAnUnreadOrFiniteAccount() throws {
    let unlimited = usefulAccount(.copilot)
    let finite = usefulAccount(.copilot, email: "other@example.com")
    let report = Snapshot(observedAt: usefulNow, identity: "person@example.com", source: "Fixture", unlimited: true)
    var preferences = MenuPreferences(); preferences.display = .byAccount
    let rows = MenuSummary.entries(accounts: [unlimited], snapshots: [unlimited.id: report], unavailable: [], preferences: preferences, now: usefulNow)
    #expect(rows.first?.isUnlimited == true)
    #expect(rows.first?.remainingPercent == nil)
    #expect(MenuSummary.entries(accounts: [unlimited], snapshots: [unlimited.id: report], unavailable: [unlimited.id], preferences: preferences, now: usefulNow).first?.isUnlimited == false)
    #expect(MenuSummary.entries(accounts: [unlimited], snapshots: [unlimited.id: report], unavailable: [], preferences: preferences, now: usefulNow.addingTimeInterval(901)).first?.isUnlimited == false)
    preferences.display = .byProvider
    let finiteReport = try usefulReading(50, identity: "other@example.com")
    let mixed = MenuSummary.entries(accounts: [unlimited, finite], snapshots: [unlimited.id: report, finite.id: finiteReport], unavailable: [], preferences: preferences, now: usefulNow)
    #expect(mixed.first?.isUnlimited == false && mixed.first?.remainingPercent == nil)
}

@Test func menuMatchesTheActionableLimitingWindowAndExpiresAfterItsReset() throws {
    let account = usefulAccount()
    var report = try usefulReading(0)
    report.windows.append(try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 20,
                                         resetsAt: usefulNow.addingTimeInterval(86400), durationMinutes: 10080))
    let entries = MenuSummary.entries(accounts: [account], snapshots: [account.id: report], unavailable: [], preferences: MenuPreferences(), now: usefulNow)
    #expect(entries.first?.remainingPercent == 0)
    #expect(entries.first?.remainingPercent == AllowanceStatus.evaluate(snapshot: report, kind: .claudeCode, now: usefulNow).remainingPercent)
    report.windows[0].resetsAt = usefulNow
    #expect(MenuSummary.entries(accounts: [account], snapshots: [account.id: report], unavailable: [], preferences: MenuPreferences(), now: usefulNow).first?.remainingPercent == nil)
}

@Test func providerSchedulesKeepCostQueriesSlowAndManualThrottlingCorrect() {
    #expect(ConnectionKind.claudeCode.refreshInterval(visible: true) == 60)
    #expect(ConnectionKind.codex.refreshInterval(visible: false) == 600)
    #expect(ConnectionKind.copilot.refreshInterval(visible: true, lowPower: true) == 900)
    #expect(ConnectionKind.openRouter.refreshInterval(visible: true) == 300)
    #expect(ConnectionKind.vercelGateway.refreshInterval(visible: false) == 600)
    #expect(ConnectionKind.openAIAPI.refreshInterval(visible: true) == 3600)
    #expect(ConnectionKind.claudeAPI.freshnessInterval == 7200)
    for kind in ConnectionKind.allCases { #expect(kind.freshnessInterval > kind.refreshInterval(visible: false, lowPower: true)) }
    var state = PollState(); state.succeeded(at: usefulNow, interval: 3600)
    #expect(!state.shouldRefresh(at: usefulNow.addingTimeInterval(29), manual: true))
    #expect(state.shouldRefresh(at: usefulNow.addingTimeInterval(30), manual: true))
    #expect(!state.shouldRefresh(at: usefulNow.addingTimeInterval(3599)))
    state.failed(UsageError.rateLimited(7200), at: usefulNow)
    #expect(!state.shouldRefresh(at: usefulNow.addingTimeInterval(3600), manual: true))
}

@Test func claudeIdentityBindingRejectsChangedMissingAndDuplicateAccountsWithoutCrossProviderCollision() throws {
    let account = usefulAccount()
    #expect(throws: UsageError.accountChanged("person@example.com")) {
        try CodexIdentity.validate(usefulReading(90, identity: "wrong@example.com"), for: account, accounts: [account], snapshots: [:])
    }
    var missing = try usefulReading(90); missing.identity = nil
    #expect(throws: UsageError.authentication) { try CodexIdentity.validate(missing, for: account, accounts: [account], snapshots: [:]) }
    let duplicate = usefulAccount()
    #expect(throws: UsageError.duplicateAccount("Personal")) {
        try CodexIdentity.validate(usefulReading(90), for: account, accounts: [account, duplicate], snapshots: [:])
    }
    #expect(try CodexIdentity.validate(usefulReading(90), for: account, accounts: [account, usefulAccount(.codex)], snapshots: [:]) == "person@example.com")
}

@Test func statusUsesLimitingApplicableQuotaAndNeverAssumesResetRecovery() throws {
    var reading = try usefulReading(0)
    reading.windows += [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 10, durationMinutes: 10080),
                        try QuotaWindow(id: "week.some model", label: "One model", usedPercent: 100, durationMinutes: 10080)]
    let exhausted = AllowanceStatus.evaluate(snapshot: reading, kind: .claudeCode, now: usefulNow)
    #expect(exhausted.state == .exhausted)
    #expect(exhausted.remainingPercent == 0)
    #expect(exhausted.resetText(at: usefulNow) == "Resets in 2h 0m")
    reading.windows[0].usedPercent = 50
    #expect(AllowanceStatus.evaluate(snapshot: reading, kind: .claudeCode, now: usefulNow).state == .ready)
    reading.windows[0].resetsAt = usefulNow
    #expect(AllowanceStatus.evaluate(snapshot: reading, kind: .claudeCode, now: usefulNow).state == .stale)
    reading.providerRestricted = true
    #expect(AllowanceStatus.evaluate(snapshot: reading, kind: .claudeCode, now: usefulNow).state == .restricted)
    #expect(AllowanceStatus.evaluate(snapshot: nil, kind: .copilot, now: usefulNow).state == .unavailable)
    #expect(AllowanceStatus.evaluate(snapshot: Snapshot(observedAt: usefulNow, source: "Fixture", unlimited: true), kind: .copilot, now: usefulNow).state == .unlimited)
}

@Test func newSnapshotFieldsStayBackwardCompatibleAndValidateMoney() throws {
    let legacy = Data(#"{"observedAt":0,"windows":[],"source":"Legacy"}"#.utf8)
    let old = try JSONDecoder().decode(Snapshot.self, from: legacy)
    #expect(old.freshnessInterval == nil && old.balanceUSD == nil && old.unlimited == nil)
    let balance = Snapshot(observedAt: usefulNow, source: "Fixture", balanceUSD: Decimal(string: "-0.25"), freshnessInterval: 1800)
    #expect(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(balance)) == balance)
    #expect(AllowanceStatus.evaluate(snapshot: balance, kind: .xai, now: usefulNow).state == .exhausted)
    let invalid = Snapshot(observedAt: usefulNow, costUSD: -1, source: "Fixture")
    #expect(throws: UsageError.invalidData) { try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(invalid)) }
    #expect(throws: UsageError.invalidData) { try Snapshot(observedAt: usefulNow, source: "Fixture", balanceUSD: .nan).validated() }
    let report = Snapshot(observedAt: usefulNow, costUSD: 2, source: "Fixture", freshnessInterval: 7200)
    #expect(!report.isStale(at: usefulNow.addingTimeInterval(3601)))
    let calendar = Calendar(identifier: .gregorian)
    let nextMonth = try #require(calendar.date(byAdding: .month, value: 1, to: CostAdapter.monthStart(usefulNow)))
    let monthEnd = nextMonth.addingTimeInterval(-10)
    let previousMonth = Snapshot(observedAt: monthEnd, costUSD: 2, periodStart: CostAdapter.monthStart(monthEnd), source: "Fixture", freshnessInterval: 7200)
    #expect(previousMonth.isStale(at: nextMonth))
}

@Test func cacheIsPrivateBoundedIdentityBoundAndKeepsOriginalResetAndAge() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SnapshotCache(root: root)
    let account = usefulAccount()
    let snapshot = try usefulReading(0)
    try cache.save(snapshot, for: account)
    let loaded = try #require(cache.load(accounts: [account], now: usefulNow)[account.id])
    #expect(loaded.observedAt == usefulNow)
    #expect(loaded.isStale(at: usefulNow.addingTimeInterval(7201)))
    #expect(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Readings/\(account.id.uuidString).json").path)[.posixPermissions] as? Int == 0o600)
    var changed = account; changed.expectedIdentity = "other@example.com"
    #expect(cache.load(accounts: [changed], now: usefulNow).isEmpty)
    var unbound = account; unbound.expectedIdentity = nil
    #expect(cache.load(accounts: [unbound], now: usefulNow).isEmpty)
    #expect(throws: UsageError.authentication) { try cache.save(snapshot, for: unbound) }
    for index in 1...5 {
        try cache.save(usefulReading(50, at: usefulNow.addingTimeInterval(Double(index * 60))), for: account)
    }
    #expect(cache.loadHistory(accounts: [account], now: usefulNow.addingTimeInterval(300))[account.id]?.count == 2)
    for index in 1...120 {
        let date = usefulNow.addingTimeInterval(Double(index * 600))
        try cache.save(usefulReading(50, at: date, reset: date.addingTimeInterval(7200)), for: account)
    }
    #expect(cache.loadHistory(accounts: [account], now: usefulNow.addingTimeInterval(72000))[account.id]?.count == SnapshotCache.maximumPoints)
    try cache.remove(account)
    #expect(cache.load(accounts: [account], now: usefulNow).isEmpty)
}

@Test func alertTransitionsRequireFreshVerifiedReportsAndDeduplicateQuotaCycles() throws {
    let account = usefulAccount()
    var tracker = AlertTracker()
    #expect(tracker.observe(account: account, snapshot: try usefulReading(100), now: usefulNow) == nil)
    let lowDate = usefulNow.addingTimeInterval(60)
    #expect(tracker.observe(account: account, snapshot: try usefulReading(20, at: lowDate), now: lowDate)?.kind == .low)
    #expect(tracker.observe(account: account, snapshot: try usefulReading(20, at: lowDate), now: lowDate) == nil)
    let emptyDate = usefulNow.addingTimeInterval(120)
    #expect(tracker.observe(account: account, snapshot: try usefulReading(0, at: emptyDate), now: emptyDate)?.kind == .exhausted)
    var restricted = try usefulReading(100, at: usefulNow.addingTimeInterval(180)); restricted.providerRestricted = true
    #expect(tracker.observe(account: account, snapshot: restricted, now: restricted.observedAt) == nil)
    #expect(tracker.observe(account: account, snapshot: try usefulReading(100), now: usefulNow.addingTimeInterval(9000)) == nil)
    let freshDate = usefulNow.addingTimeInterval(240)
    let recovered = try usefulReading(100, at: freshDate)
    #expect(tracker.observe(account: account, snapshot: recovered, now: freshDate)?.kind == .recovered)
    tracker = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(tracker))
    let later = usefulNow.addingTimeInterval(300)
    #expect(tracker.observe(account: account, snapshot: try usefulReading(20, at: later), now: later) == nil)
    tracker.remove(account.id)
    #expect(tracker.observe(account: account, snapshot: recovered, now: freshDate) == nil)
}

@Test func creditAlertsReportBalancesWithoutPromisingThatRequestsWillSucceed() throws {
    for (kind, label) in [(ConnectionKind.openRouter, "key budget"), (.vercelGateway, "team credits"), (.xai, "prepaid credits")] {
        let account = Account(name: "Example", kind: kind)
        var tracker = AlertTracker()
        func report(_ balance: Decimal, offset: TimeInterval) -> Snapshot {
            Snapshot(observedAt: usefulNow.addingTimeInterval(offset), source: "Fixture", balanceUSD: balance)
        }
        #expect(tracker.observe(account: account, snapshot: report(10, offset: 0), now: usefulNow) == nil)
        let emptyResult = tracker.observe(account: account, snapshot: report(-1, offset: 60), now: usefulNow.addingTimeInterval(60))
        let empty = try #require(emptyResult)
        #expect(empty.kind == .exhausted)
        #expect(empty.title.contains(label + " empty"))
        #expect(!empty.title.contains("allowance"))
        let restoredResult = tracker.observe(account: account, snapshot: report(10, offset: 120), now: usefulNow.addingTimeInterval(120))
        let restored = try #require(restoredResult)
        #expect(restored.kind == .recovered)
        #expect(restored.title.contains(label))
        #expect(restored.title.contains(kind == .openRouter ? "replenished" : "restored"))
        #expect(!restored.title.contains("available") && !restored.message.contains("available"))
        #expect(restored.message.contains("limits"))
    }
}
