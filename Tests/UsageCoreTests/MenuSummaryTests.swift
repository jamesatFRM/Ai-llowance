import Foundation
import Testing
@testable import UsageCore

private let menuTime = Date(timeIntervalSince1970: 1_790_000_000)
private func weeklyReading(_ remaining: Double, kind: ConnectionKind, sessionRemaining: Double = 100) throws -> Snapshot {
    Snapshot(observedAt: menuTime, windows: [
        try QuotaWindow(id: kind == .claudeCode ? "session" : "codex.Primary", label: "Session", usedPercent: 100 - sessionRemaining, resetsAt: menuTime.addingTimeInterval(3600), durationMinutes: 300),
        try QuotaWindow(id: kind == .claudeCode ? "week.all models" : "codex.Secondary", label: "Week", usedPercent: 100 - remaining, resetsAt: menuTime.addingTimeInterval(86400), durationMinutes: 10_080),
        try QuotaWindow(id: "week.Fable", label: "Fable", usedPercent: 100, resetsAt: menuTime.addingTimeInterval(86400), durationMinutes: 10_080)
    ], source: "Fixture")
}

@Test func providerAveragesWeeklyAndSessionSeparatelyAndIgnoreModelSpecificLimits() throws {
    let claude1 = Account(name: "Claude", kind: .claudeCode)
    let claude2 = Account(name: "Claude 2", kind: .claudeCode)
    let openAI = Account(name: "OpenAI", kind: .codex)
    let snapshots = [claude1.id: try weeklyReading(4, kind: .claudeCode, sessionRemaining: 2), claude2.id: try weeklyReading(100, kind: .claudeCode), openAI.id: try weeklyReading(80, kind: .codex)]
    var preferences = MenuPreferences(); preferences.display = .byProvider
    let entries = MenuSummary.entries(accounts: [claude1, claude2, openAI], snapshots: snapshots, unavailable: [], preferences: preferences, now: menuTime)
    #expect(entries.map(\.provider) == [.claude, .openAI])
    #expect(entries.map(\.remainingPercent) == [52, 80])
    #expect(entries.map(\.accountCount) == [2, 1])
    #expect(snapshots[claude1.id]?.sessionWindow(for: .claudeCode)?.remainingPercent == 2)
}

@Test func expiredSessionCannotBeIgnoredToShowHealthyWeeklyAllowance() throws {
    for kind in [ConnectionKind.claudeCode, .codex] {
        let account = Account(name: "Example", kind: kind)
        var snapshot = try weeklyReading(90, kind: kind, sessionRemaining: 0)
        snapshot.windows[0].resetsAt = menuTime
        for mode in MenuDisplay.allCases {
            var preferences = MenuPreferences(); preferences.display = mode
            let entries = MenuSummary.entries(accounts: [account], snapshots: [account.id: snapshot], unavailable: [], preferences: preferences, now: menuTime)
            #expect(entries.first?.remainingPercent == nil)
            #expect(entries.first?.isUnlimited == false)
        }
    }
}

@Test func combinedAndSelectedModesUseOnlyEnabledChosenSubscriptionAccounts() throws {
    let a = Account(name: "A", kind: .claudeCode)
    let b = Account(name: "B", kind: .codex)
    let paused = Account(name: "Paused", kind: .codex, enabled: false)
    let api = Account(name: "Billing", kind: .claudeAPI)
    let snapshots = [a.id: try weeklyReading(20, kind: .claudeCode), b.id: try weeklyReading(80, kind: .codex)]
    var preferences = MenuPreferences(); preferences.display = .combined
    func entries() -> [MenuEntry] { MenuSummary.entries(accounts: [a, b, paused, api], snapshots: snapshots, unavailable: [], preferences: preferences, now: menuTime) }
    #expect(entries().first?.remainingPercent == 50)
    preferences.aggregation = .lowest
    #expect(entries().first?.remainingPercent == 20)
    preferences.display = .byAccount; preferences.allAccounts = false; preferences.selectedAccountIDs = [b.id]
    #expect(entries().map(\.label) == ["B"])
    #expect(entries().first?.remainingPercent == 80)
    preferences.selectedAccountIDs = []
    #expect(entries().isEmpty)
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
}

@Test func missingStaleOrFailedAccountDoesNotProduceMisleadingGroupAverage() throws {
    let a = Account(name: "A", kind: .claudeCode)
    let b = Account(name: "B", kind: .claudeCode)
    let reading = try weeklyReading(100, kind: .claudeCode)
    var prefs = MenuPreferences(); prefs.display = .byProvider
    let missing = MenuSummary.entries(accounts: [a,b], snapshots: [a.id: reading], unavailable: [], preferences: prefs, now: menuTime)
    #expect(missing.first?.remainingPercent == nil)
    let failed = MenuSummary.entries(accounts: [a,b], snapshots: [a.id: reading,b.id: reading], unavailable: [b.id], preferences: prefs, now: menuTime)
    #expect(failed.first?.remainingPercent == nil)
    let stale = MenuSummary.entries(accounts: [a], snapshots: [a.id: reading], unavailable: [], preferences: prefs, now: menuTime.addingTimeInterval(901))
    #expect(stale.first?.remainingPercent == nil)
}

@Test func modelSpecificClaudeQuotaCannotMasqueradeAsOverallAllowance() throws {
    let report = Snapshot(observedAt: menuTime, windows: [try QuotaWindow(id: "week.Fable", label: "Fable", usedPercent: 0, durationMinutes: 10_080)], source: "Fixture")
    #expect(report.primaryWeeklyWindow(for: .claudeCode) == nil)
}

@Test func compactMenuPreferencePreservesExistingSavedSettings() throws {
    let data = Data(#"{"display":"byAccount","aggregation":"average","allAccounts":false,"selectedAccountIDs":[]}"#.utf8)
    var settings = try JSONDecoder().decode(MenuPreferences.self, from: data)
    #expect(settings.showAccountNames)
    #expect(settings.theme == .automatic)
    #expect(settings.display == .byAccount)
    #expect(!settings.allAccounts)
    settings.showAccountNames = false
    settings.theme = .light
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func quotaColorsUseRemainingAllowanceAtExactBoundaries() {
    #expect(AllowanceBand.remaining(100) == .normal)
    #expect(AllowanceBand.remaining(30) == .normal)
    #expect(AllowanceBand.remaining(29.99) == .warning)
    #expect(AllowanceBand.remaining(20.01) == .warning)
    #expect(AllowanceBand.remaining(20) == .critical)
    #expect(AllowanceBand.remaining(0) == .critical)
}


@Test func weeklyIsPrimaryAndFiveHourAllowanceIsExplicitForClaudeAndCodex() throws {
    for kind in [ConnectionKind.claudeCode, .codex] {
        let account = Account(name: "Work", kind: kind)
        let reading = try weeklyReading(97, kind: kind, sessionRemaining: 93)
        let preferences = MenuPreferences()
        let entry = try #require(MenuSummary.entries(accounts: [account], snapshots: [account.id: reading], unavailable: [], preferences: preferences, now: menuTime).first)
        #expect(entry.remainingPercent == 97)
        #expect(entry.sessionRemainingPercent == 93)
        #expect(MenuEntryPresentation.value(entry, preferences: preferences) == "w 97% · 5h 93%")
        #expect(reading.displayWindow(for: kind)?.remainingPercent == 97)
        #expect(AllowanceStatus.evaluate(snapshot: try weeklyReading(97, kind: kind, sessionRemaining: 0), kind: kind, now: menuTime).state == .exhausted)
    }
}

@Test func weeklyHistoryStartsANewSegmentWithoutDeletingEarlierSessionSamples() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Work", kind: .claudeCode); account.expectedIdentity = "work@example.com"
    let cache = SnapshotCache(root: root)
    var first = try weeklyReading(97, kind: .claudeCode, sessionRemaining: 93)
    first.identity = account.expectedIdentity
    first.windows.removeAll { $0.durationMinutes != 300 }
    try cache.save(first, for: account)
    var next = try weeklyReading(97, kind: .claudeCode, sessionRemaining: 93)
    next.identity = account.expectedIdentity; next.observedAt = menuTime.addingTimeInterval(1)
    let history = try cache.save(next, for: account)
    #expect(history.map(\.remainingPercent) == [93, 97])
    #expect(history.map(\.windowID) == ["session", "week.all models"])
}
