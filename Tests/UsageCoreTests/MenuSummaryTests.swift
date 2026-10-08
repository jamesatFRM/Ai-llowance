import Foundation
import Testing
@testable import UsageCore

private let menuTime = Date(timeIntervalSince1970: 1_790_000_000)
private func weeklyReading(_ remaining: Double, kind: ConnectionKind, sessionRemaining: Double = 1) throws -> Snapshot {
    Snapshot(observedAt: menuTime, windows: [
        try QuotaWindow(id: kind == .claudeCode ? "session" : "codex.Primary", label: "Session", usedPercent: 100 - sessionRemaining, resetsAt: menuTime.addingTimeInterval(-1), durationMinutes: 300),
        try QuotaWindow(id: kind == .claudeCode ? "week.all models" : "codex.Secondary", label: "Week", usedPercent: 100 - remaining, resetsAt: menuTime.addingTimeInterval(86400), durationMinutes: 10_080),
        try QuotaWindow(id: "week.Fable", label: "Fable", usedPercent: 100, resetsAt: menuTime.addingTimeInterval(86400), durationMinutes: 10_080)
    ], source: "Fixture")
}

@Test func providerAveragesCountAccountsOnceAndIgnoreOtherLimits() throws {
    let claude1 = Account(name: "Claude", kind: .claudeCode)
    let claude2 = Account(name: "Claude 2", kind: .claudeCode)
    let openAI = Account(name: "OpenAI", kind: .codex)
    let snapshots = [claude1.id: try weeklyReading(4, kind: .claudeCode), claude2.id: try weeklyReading(100, kind: .claudeCode), openAI.id: try weeklyReading(80, kind: .codex)]
    let entries = MenuSummary.entries(accounts: [claude1, claude2, openAI], snapshots: snapshots, unavailable: [], preferences: MenuPreferences(), now: menuTime)
    #expect(entries.map(\.provider) == [.claude, .openAI])
    #expect(entries.map(\.remainingPercent) == [52, 80])
    #expect(entries.map(\.accountCount) == [2, 1])
    #expect(snapshots[claude1.id]?.sessionWindow(for: .claudeCode)?.remainingPercent == 1)
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
    let prefs = MenuPreferences()
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
