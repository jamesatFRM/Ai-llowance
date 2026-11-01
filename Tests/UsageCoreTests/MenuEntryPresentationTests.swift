import Foundation
import Testing
@testable import UsageCore

@Test func groupedAllowanceExplainsTheScreenshotAverage() {
    var preferences = MenuPreferences()
    preferences.display = .byProvider
    let entry = MenuEntry(provider: .claude, label: "Claude", remainingPercent: 46, accountCount: 2)
    #expect(MenuEntryPresentation.value(entry, preferences: preferences) == "46% avg")
    preferences.aggregation = .lowest
    let lowest = MenuEntry(provider: .claude, label: "Claude", remainingPercent: 0, accountCount: 2)
    #expect(MenuEntryPresentation.value(lowest, preferences: preferences) == "0% lowest")
}
@Test func singleAccountsAndDollarBalancesNeverGetAverageLabels() {
    let preferences = MenuPreferences()
    #expect(preferences.display == .byAccount)
    let account = MenuEntry(provider: .claude, label: "Work", remainingPercent: 92, accountCount: 1)
    #expect(MenuEntryPresentation.title(account, preferences: preferences) == "Work 92%")
    let balance = MenuEntry(provider: .xai, label: "xAI", remainingPercent: nil, accountCount: 1, balanceUSD: 6.3, isBalance: true)
    #expect(MenuEntryPresentation.value(balance, preferences: preferences) == "$6.3")
}

@Test func fiveHourMenuVisibilityIsIndependentAndPersists() throws {
    var preferences = MenuPreferences()
    let entry = MenuEntry(provider: .claude, label: "Work", remainingPercent: 97, accountCount: 1,
                          primaryPeriod: "Week", sessionRemainingPercent: 93, showsSession: true)
    #expect(MenuEntryPresentation.value(entry, preferences: preferences) == "w 97% · 5h 93%")
    preferences.showSessionInMenuBar = false
    preferences.detailedQuotaLabels = true
    let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.detailedQuotaLabels)
    #expect(!restored.showSessionInMenuBar)
    #expect(MenuEntryPresentation.value(entry, preferences: restored) == "97%")
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8)).showSessionInMenuBar)
}

@Test func weeklyMenuLabelChoicesPersistAndRespectSessionVisibility() throws {
    var preferences = MenuPreferences()
    let entry = MenuEntry(provider: .claude, label: "Work", remainingPercent: 97, accountCount: 1,
                          primaryPeriod: "Week", sessionRemainingPercent: 93, showsSession: true)
    for (label, expected) in [(WeeklyMenuLabel.none, "97% · 5h 93%"), (.short, "w 97% · 5h 93%"), (.full, "Week 97% · 5h 93%")] {
        preferences.weeklyMenuLabel = label
        let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.weeklyMenuLabel == label)
        #expect(MenuEntryPresentation.value(entry, preferences: restored) == expected)
        preferences.showSessionInMenuBar = false
        #expect(MenuEntryPresentation.value(entry, preferences: preferences) == "97%")
        preferences.showSessionInMenuBar = true
    }
}

@Test func sessionLabelChoicesPersistWithoutHidingReadings() throws {
    var preferences = MenuPreferences()
    preferences.weeklyMenuLabel = .none
    let entry = MenuEntry(provider: .claude, label: "Work", remainingPercent: 97, accountCount: 1,
                          primaryPeriod: "Week", sessionRemainingPercent: 93, showsSession: true)
    let sessionOnly = MenuEntry(provider: .claude, label: "Work", remainingPercent: 93, accountCount: 1, primaryPeriod: "5h")
    for (label, prefix) in [(SessionMenuLabel.none, ""), (.short, "5h "), (.full, "5-Hour ")] {
        preferences.sessionMenuLabel = label
        let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.sessionMenuLabel == label)
        #expect(MenuEntryPresentation.value(entry, preferences: restored) == "97% · " + prefix + "93%")
        #expect(MenuEntryPresentation.value(sessionOnly, preferences: restored) == prefix + "93%")
    }
}

@Test func dropdownCustomizationsPersistIndependently() throws {
    var preferences = MenuPreferences()
    preferences.dropdownShowEmails = true
    preferences.dropdownShowResets = false
    preferences.dropdownShowBars = false
    preferences.dropdownShowRecentUsage = true
    preferences.dropdownShowHeadings = false
    preferences.dropdownRoomyRows = true
    let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored == preferences)
    let legacy = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(!legacy.dropdownShowRecentUsage)
    #expect(!legacy.dropdownShowEmails && legacy.dropdownShowResets && legacy.dropdownShowBars && legacy.dropdownShowHeadings && !legacy.dropdownRoomyRows)
    #expect(restored.showSessionInMenuBar && !restored.detailedQuotaLabels)
}

@Test func dashboardChartStylesPersistWithoutChangingOtherPreferences() throws {
    for style in DashboardChartStyle.allCases {
        var preferences = MenuPreferences()
        preferences.dashboardChartStyle = style
        preferences.dashboardChartFullScale = true
        preferences.dropdownShowEmails = true
        preferences.showSessionInMenuBar = false
        let restored = try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored == preferences)
    }
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8)).dashboardChartStyle == .mixed)
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: Data(#"{"dashboardChartStyle":"future-style"}"#.utf8)).dashboardChartStyle == .mixed)
    #expect(DashboardChartStyle.allCases.filter(\.isCurrentAllowance) == [.ring, .pie, .gauge])
}
