import Foundation
import Testing
@testable import UsageCore

private let integrityNow = Date(timeIntervalSince1970: 1_790_000_000)

private func integrityAccount() -> Account {
    var account = Account(name: "Example", kind: .claudeCode)
    account.expectedIdentity = "person@example.com"
    return account
}

private func integrityReading(at date: Date, remaining: Double = 80) throws -> Snapshot {
    Snapshot(observedAt: date, windows: [try QuotaWindow(id: "session", label: "Session", usedPercent: 100 - remaining,
        resetsAt: date.addingTimeInterval(7200), durationMinutes: 300)], identity: "person@example.com", source: "Fixture")
}

@Test func exhaustedSessionCannotPromiseRecoveryBeforeExhaustedWeekResets() throws {
    for kind in [ConnectionKind.claudeCode, .codex] {
        let session = try QuotaWindow(id: kind == .claudeCode ? "session" : "codex.Primary", label: "Session", usedPercent: 100,
                                     resetsAt: integrityNow.addingTimeInterval(7200), durationMinutes: 300)
        let week = try QuotaWindow(id: kind == .claudeCode ? "week.all models" : "codex.Secondary", label: "Week", usedPercent: 100,
                                  resetsAt: integrityNow.addingTimeInterval(5 * 86400), durationMinutes: 10080)
        for windows in [[session, week], [week, session]] {
            let reading = Snapshot(observedAt: integrityNow, windows: windows, source: "Fixture")
            let status = AllowanceStatus.evaluate(snapshot: reading, kind: kind, now: integrityNow)
            #expect(reading.limitingWindow(for: kind)?.id == week.id)
            #expect(status.state == .exhausted)
            #expect(status.resetAt == week.resetsAt)
            #expect(status.resetText(at: integrityNow) == "Resets in 5d 0h")
        }
        var unknownWeek = week; unknownWeek.resetsAt = nil
        let unknown = Snapshot(observedAt: integrityNow, windows: [session, unknownWeek], source: "Fixture")
        #expect(unknown.limitingWindow(for: kind)?.id == week.id)
        #expect(AllowanceStatus.evaluate(snapshot: unknown, kind: kind, now: integrityNow).resetAt == nil)
        var availableWeek = week; availableWeek.usedPercent = 99
        let singleExhausted = Snapshot(observedAt: integrityNow, windows: [session, availableWeek], source: "Fixture")
        #expect(singleExhausted.limitingWindow(for: kind)?.id == session.id)
    }
}

@Test func providerDatesCannotOverflowElapsedTimeFormatting() throws {
    for seconds in [-1e100, -1, 253_402_300_800, 1e100] {
        let reading = Snapshot(observedAt: Date(timeIntervalSince1970: seconds), source: "Fixture")
        #expect(throws: UsageError.invalidData) { try reading.validated() }
        #expect(throws: UsageError.invalidData) { try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(reading)) }
        #expect(AllowanceStatus.evaluate(snapshot: reading, kind: .codex, now: integrityNow).state == .unavailable)
    }
    for date in [Date(timeIntervalSince1970: -1e100), Date(timeIntervalSince1970: 1e100), integrityNow.addingTimeInterval(1)] {
        #expect(throws: UsageError.invalidData) {
            try Snapshot(observedAt: integrityNow, costUSD: 1, periodStart: date, source: "Fixture").validated()
        }
    }
    #expect(try Snapshot(observedAt: integrityNow, costUSD: 1, periodStart: CostAdapter.monthStart(integrityNow), source: "Fixture").validated().costUSD == 1)
}

@Test func invalidRetryAfterCannotSuspendAConnectionIndefinitely() {
    for retry in [Double.infinity, -.infinity, .nan, -1] {
        var state = PollState()
        state.failed(UsageError.rateLimited(retry), at: integrityNow)
        #expect(!state.shouldRefresh(at: integrityNow.addingTimeInterval(299)))
        #expect(state.shouldRefresh(at: integrityNow.addingTimeInterval(300)))
    }
    for retry in [Double.greatestFiniteMagnitude, 1e100] {
        var state = PollState()
        state.failed(UsageError.rateLimited(retry), at: integrityNow)
        #expect(state.nextAttempt.timeIntervalSince1970.isFinite)
        #expect(state.shouldRefresh(at: integrityNow.addingTimeInterval(7 * 86400)))
    }
    var normal = PollState()
    normal.failed(UsageError.rateLimited(7200), at: integrityNow)
    #expect(!normal.shouldRefresh(at: integrityNow.addingTimeInterval(7199), manual: true))
    #expect(normal.shouldRefresh(at: integrityNow.addingTimeInterval(7200)))
}

@Test func delayedReadingPreservesNewerCachedValueAndHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingIntegrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let account = integrityAccount(), cache = SnapshotCache(root: root)
    let newer = try integrityReading(at: integrityNow, remaining: 10)
    let history = try cache.save(newer, for: account)
    let delayedHistory = try cache.save(integrityReading(at: integrityNow.addingTimeInterval(-30), remaining: 90), for: account)
    #expect(delayedHistory == history)
    #expect(cache.load(accounts: [account], now: integrityNow)[account.id] == newer)
    #expect(cache.loadHistory(accounts: [account], now: integrityNow)[account.id] == history)
}

@Test func corruptCachedHistoryCannotRenderOutOfOrderOrUnboundedReadings() throws {
    struct Record: Encodable {
        let accountID: UUID
        let kind: ConnectionKind
        let claudeProfileIsolated = true
        let identity: String
        let snapshot: Snapshot
        let history: [UsageHistoryPoint]
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingIntegrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let account = integrityAccount(), cache = SnapshotCache(root: root)
    let older = UsageHistoryPoint(timestamp: integrityNow.addingTimeInterval(-300), remainingPercent: 80)
    let recent = UsageHistoryPoint(timestamp: integrityNow, remainingPercent: 60)
    let histories = [
        [older, older],
        [recent, older],
        [older, UsageHistoryPoint(timestamp: integrityNow.addingTimeInterval(1), remainingPercent: 50)],
        [UsageHistoryPoint(timestamp: integrityNow, balanceUSD: Decimal(string: "1000000000000001"))],
        [UsageHistoryPoint(timestamp: integrityNow, costUSD: Decimal(string: "1000000000000001"))]
    ]
    let file = root.appendingPathComponent("Readings/\(account.id.uuidString).json")
    for history in histories {
        try Paths.write(Record(accountID: account.id, kind: account.kind, identity: "person@example.com",
                               snapshot: integrityReading(at: integrityNow), history: history), to: file)
        #expect(cache.load(accounts: [account], now: integrityNow).isEmpty)
        #expect(cache.loadHistory(accounts: [account], now: integrityNow).isEmpty)
    }
    try Paths.write(Record(accountID: account.id, kind: account.kind, identity: "person@example.com",
                           snapshot: integrityReading(at: integrityNow), history: [older, recent]), to: file)
    #expect(cache.loadHistory(accounts: [account], now: integrityNow)[account.id] == [older, recent])
}

@Test func duplicateSubscriptionBindingsCannotReloadAsTwoAccountsWhileOffline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingIntegrity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = integrityAccount()
    var duplicate = integrityAccount(); duplicate.expectedIdentity = " PERSON@EXAMPLE.COM "
    let cache = SnapshotCache(root: root), reading = try integrityReading(at: integrityNow)
    try cache.save(reading, for: first)
    try cache.save(reading, for: duplicate)
    // This is the startup cache path; no fetch or provider process is involved.
    for accounts in [[first, duplicate], [duplicate, first]] {
        #expect(cache.load(accounts: accounts, now: integrityNow).isEmpty)
        #expect(cache.loadHistory(accounts: accounts, now: integrityNow).isEmpty)
    }
    duplicate.enabled = false
    #expect(cache.load(accounts: [first, duplicate], now: integrityNow).isEmpty)
    // Removing the duplicate restores the original private cache without rewriting it.
    #expect(cache.load(accounts: [first], now: integrityNow)[first.id] == reading)
    #expect(cache.loadHistory(accounts: [first], now: integrityNow)[first.id]?.count == 1)
    var otherProvider = integrityAccount(); otherProvider.kind = .codex
    try cache.save(reading, for: otherProvider)
    #expect(cache.load(accounts: [first, otherProvider], now: integrityNow).count == 2)
    let api1 = Account(name: "Key A", kind: .openRouter), api2 = Account(name: "Key B", kind: .openRouter)
    let balance = Snapshot(observedAt: integrityNow, source: "Fixture", balanceUSD: 5)
    try cache.save(balance, for: api1); try cache.save(balance, for: api2)
    #expect(cache.load(accounts: [api1, api2], now: integrityNow).count == 2)
}

@Test func menuSelectionCannotHideDuplicateOrChangedSubscriptionIdentity() throws {
    let first = integrityAccount()
    var duplicate = integrityAccount(); duplicate.expectedIdentity = " PERSON@EXAMPLE.COM "
    let reading = try integrityReading(at: integrityNow)
    let snapshots = [first.id: reading, duplicate.id: reading]
    for display in MenuDisplay.allCases {
        var preferences = MenuPreferences(); preferences.display = display
        let entries = MenuSummary.entries(accounts: [first, duplicate], snapshots: snapshots, unavailable: [], preferences: preferences, now: integrityNow)
        #expect(entries.allSatisfy { $0.remainingPercent == nil && !$0.isUnlimited })
        preferences.allAccounts = false; preferences.selectedAccountIDs = [first.id]
        #expect(MenuSummary.entries(accounts: [first, duplicate], snapshots: snapshots, unavailable: [], preferences: preferences, now: integrityNow).first?.remainingPercent == nil)
    }
    duplicate.enabled = false
    #expect(MenuSummary.entries(accounts: [first, duplicate], snapshots: snapshots, unavailable: [], preferences: MenuPreferences(), now: integrityNow).first?.remainingPercent == nil)
    var wrong = reading; wrong.identity = "other@example.com"
    #expect(MenuSummary.entries(accounts: [first], snapshots: [first.id: wrong], unavailable: [], preferences: MenuPreferences(), now: integrityNow).first?.remainingPercent == nil)
    var unlimited = wrong; unlimited.windows = []; unlimited.unlimited = true
    #expect(MenuSummary.entries(accounts: [first], snapshots: [first.id: unlimited], unavailable: [], preferences: MenuPreferences(), now: integrityNow).first?.isUnlimited == false)
    #expect(MenuSummary.entries(accounts: [first], snapshots: [first.id: reading], unavailable: [], preferences: MenuPreferences(), now: integrityNow).first?.remainingPercent == 80)
}
