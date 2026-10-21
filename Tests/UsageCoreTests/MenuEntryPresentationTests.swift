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
