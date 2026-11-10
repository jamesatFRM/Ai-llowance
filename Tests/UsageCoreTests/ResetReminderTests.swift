import Foundation
import Testing
@testable import UsageCore

private let reminderNow = Date(timeIntervalSince1970: 1_800_000_000)
private func reminderAccount() -> Account {
    var account = Account(name: "Work", kind: .claudeCode)
    account.expectedIdentity = "fixture@example.com"
    return account
}
private func reminderReading(at now: Date = reminderNow, remaining: Double = 75, resetHours: Double = 24) throws -> Snapshot {
    Snapshot(observedAt: now, windows: [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 100 - remaining,
        resetsAt: now.addingTimeInterval(resetHours * 3600), durationMinutes: 10080)], identity: "fixture@example.com", source: "Fixture")
}
@Test func resetReminderIncludesRemainingAndTimeAndDeduplicatesAcrossRestart() throws {
    var tracker = AlertTracker()
    let account = reminderAccount(), reading = try reminderReading()
    let first = tracker.observeResetReminder(account: account, snapshot: reading, now: reminderNow, leadHours: 24, minimumRemaining: 25)
    let alert = try #require(first)
    #expect(alert.kind == .resetReminder)
    #expect(alert.message.contains("75%") && alert.message.contains("1 day"))
    var restored = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(tracker))
    let result1 = restored.observeResetReminder(account: account, snapshot: reading, now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result1 == nil)
    let next = reminderNow.addingTimeInterval(7*86400)
    let result2 = restored.observeResetReminder(account: account, snapshot: try reminderReading(at: next), now: next, leadHours: 24, minimumRemaining: 25)
    #expect(result2 != nil)
}
@Test func resetReminderRejectsOutOfRangeStaleMissingAndWrongIdentity() throws {
    var tracker = AlertTracker(); let account = reminderAccount()
    let result3 = tracker.observeResetReminder(account: account, snapshot: try reminderReading(resetHours: 25), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result3 == nil)
    let result4 = tracker.observeResetReminder(account: account, snapshot: try reminderReading(remaining: 24), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result4 == nil)
    var reading = try reminderReading()
    reading.identity = "other@example.com"
    let result5 = tracker.observeResetReminder(account: account, snapshot: reading, now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result5 == nil)
    reading = try reminderReading(); reading.windows[0].resetsAt = nil
    let result6 = tracker.observeResetReminder(account: account, snapshot: reading, now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result6 == nil)
    reading = try reminderReading()
    let result7 = tracker.observeResetReminder(account: account, snapshot: reading, now: reminderNow.addingTimeInterval(3600), leadHours: 24, minimumRemaining: 25)
    #expect(result7 == nil)
    let result8 = tracker.observeResetReminder(account: account, snapshot: try reminderReading(resetHours: -1), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result8 == nil)
}
@Test func resetReminderIsIndependentPerAccountAndToleratesResetClockRounding() throws {
    var tracker = AlertTracker(); let a = reminderAccount(); var b = reminderAccount(); b.id = UUID()
    let result9 = tracker.observeResetReminder(account: a, snapshot: try reminderReading(resetHours: 23), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result9 != nil)
    let result10 = tracker.observeResetReminder(account: b, snapshot: try reminderReading(resetHours: 23), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result10 != nil)
    let result11 = tracker.observeResetReminder(account: a, snapshot: try reminderReading(resetHours: 23.01), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result11 == nil)
    tracker.remove(a.id)
    let result12 = tracker.observeResetReminder(account: a, snapshot: try reminderReading(resetHours: 23), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result12 != nil)
}
@Test func resetReminderSettingsAreBackwardCompatibleAndPersistent() throws {
    let defaults = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(!defaults.resetRemindersEnabled && defaults.resetReminderLeadHours == 24 && defaults.resetReminderMinimumPercent == 25)
    var preferences = defaults; preferences.resetRemindersEnabled = true; preferences.resetReminderLeadHours = 6; preferences.resetReminderMinimumPercent = 75
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    var legacy = try JSONDecoder().decode(AlertTracker.self, from: Data("{\"observations\":[]}".utf8))
    let result13 = legacy.observeResetReminder(account: reminderAccount(), snapshot: try reminderReading(), now: reminderNow, leadHours: 24, minimumRemaining: 25)
    #expect(result13 != nil)
}

@Test func twoResetReminderRulesHaveIndependentTimesThresholdsAndPersistentDeduplication() throws {
    var tracker = AlertTracker(); let account = reminderAccount()
    let early = try reminderReading(remaining: 80, resetHours: 72)
    let reminder2 = tracker.observeResetReminder(account: account, snapshot: early, now: reminderNow, leadHours: 72, minimumRemaining: 75, rule: 1)
    let notYet = tracker.observeResetReminder(account: account, snapshot: early, now: reminderNow, leadHours: 48, minimumRemaining: 50)
    #expect(reminder2 != nil && notYet == nil)
    var restored = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(tracker))
    let later = reminderNow.addingTimeInterval(86400)
    let reading = try reminderReading(at: later, remaining: 60, resetHours: 48)
    let reminder1 = restored.observeResetReminder(account: account, snapshot: reading, now: later, leadHours: 48, minimumRemaining: 50)
    #expect(reminder1 != nil)
    let repeat1 = restored.observeResetReminder(account: account, snapshot: reading, now: later, leadHours: 48, minimumRemaining: 50)
    let repeat2 = restored.observeResetReminder(account: account, snapshot: early, now: reminderNow, leadHours: 72, minimumRemaining: 75, rule: 1)
    #expect(repeat1 == nil && repeat2 == nil)
    restored.remove(account.id)
    let removed = restored.observeResetReminder(account: account, snapshot: reading, now: later, leadHours: 48, minimumRemaining: 50)
    #expect(removed != nil)
}

@Test func arbitraryReminderPercentageAndBothSettingsPersist() throws {
    var preferences = MenuPreferences()
    preferences.resetRemindersEnabled = true; preferences.resetReminderMinimumPercent = 37; preferences.resetReminderLeadHours = 48
    preferences.secondResetReminderEnabled = true; preferences.secondResetReminderMinimumPercent = 83; preferences.secondResetReminderLeadHours = 72
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    var tracker = AlertTracker(); let account = reminderAccount()
    let below = tracker.observeResetReminder(account: account, snapshot: try reminderReading(remaining: 36), now: reminderNow, leadHours: 24, minimumRemaining: 37)
    let exact = tracker.observeResetReminder(account: account, snapshot: try reminderReading(remaining: 37), now: reminderNow, leadHours: 24, minimumRemaining: 37)
    #expect(below == nil && exact != nil)
}
