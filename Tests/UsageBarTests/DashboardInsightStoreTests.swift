import Foundation
import Testing
import UsageCore
@testable import UsageBar

@Test @MainActor func insightCardsAndAllTheirChoicesSurviveARestartWithoutProviderReads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("InsightChoices-\(UUID())")
    try Paths.prepare(root); defer { try? FileManager.default.removeItem(at:root) }
    let store = AppStore(root:root,monitor:false)
    var subscription = Account(name:"Personal",kind:.codex);subscription.expectedIdentity="fixture@example.com"
    let credits = Account(name:"Credits",kind:.vercelGateway)
    store.accounts = [subscription,credits]
    let id = try #require(store.addInsight(.burnRate,accountID:subscription.id))
    store.updateInsight(id) { $0.chart = .bars; $0.period = .hours; $0.size = .full; $0.collapsed = true; $0.metric = .session }
    let key = "insight:" + id.uuidString
    store.setDashboardTileHidden(key,hidden:true)
    store.moveDashboardTile(key,offset:-1,includingHidden:true)
    let expected = store.menuPreferences
    await store.shutdown()
    let restored = AppStore(root:root,monitor:false)
    #expect(restored.accounts.map(\.id) == [subscription.id,credits.id])
    #expect(restored.menuPreferences == expected)
    #expect(restored.menuPreferences.dashboardLayout.insights.first?.accountID == subscription.id)
    #expect(restored.refreshingAccounts.isEmpty)
    await restored.shutdown()
}

@Test @MainActor func insightAccountSelectionCannotCrossUnsupportedMetricsOrSilentlyReplaceADeletedAccount() async throws {
    let store = AppStore(demo:true)
    let subscription = store.accounts[0], credits = Account(name:"Credits",kind:.vercelGateway)
    store.accounts.append(credits)
    let id = try #require(store.addInsight(.creditRunway,accountID:subscription.id))
    #expect(store.menuPreferences.dashboardLayout.insights.first { $0.id == id }?.accountID == credits.id)
    store.setInsightAccount(id,accountID:subscription.id)
    #expect(store.menuPreferences.dashboardLayout.insights.first { $0.id == id }?.accountID == credits.id)
    store.accounts.removeAll { $0.id == credits.id }
    #expect(store.menuPreferences.dashboardLayout.insights.first { $0.id == id }?.accountID == credits.id)
    #expect(store.addInsight(.creditRunway) == nil)
    await store.shutdown()
}

@Test @MainActor func dashboardRestoreKeepsConnectionsColorsAndChartChoicesAndCollapsedCardsIncludeInsights() async throws {
    let store = AppStore(demo:true)
    let first = store.accounts[0].id
    store.accounts[0].graphColorHex = "12AB34";store.accounts[0].dashboardChartStyle = .ring
    _ = store.addInsight(.weeklyPace,accountID:first)
    store.setAllDashboardCollapsed(true)
    #expect(store.dashboardAllCollapsed)
    #expect(store.menuPreferences.dashboardLayout.insights.allSatisfy { $0.collapsed })
    store.setDashboardTileHidden(DashboardLayoutPreferences.accountTileID(first),hidden:true)
    store.moveDashboardTile("activity",offset:-1)
    store.resetDashboardAccountOrder()
    #expect(store.menuPreferences.dashboardLayout.order.isEmpty)
    #expect(store.menuPreferences.dashboardLayout.hidden.contains(DashboardLayoutPreferences.accountTileID(first)))
    store.restoreDashboardLayout()
    #expect(store.menuPreferences.dashboardLayout.insights.isEmpty && store.menuPreferences.dashboardLayout.hidden.isEmpty)
    #expect(store.accounts[0].id == first && store.accounts[0].graphColorHex == "12AB34" && store.accounts[0].dashboardChartStyle == .ring)
    #expect(!store.dashboardAllCollapsed)
    await store.shutdown()
}

@Test @MainActor func optionalCardsAreBoundedAndCannotStartRefreshes() async throws {
    let store = AppStore(demo:true)
    for _ in 0..<DashboardLayoutPreferences.maximumInsights { #expect(store.addInsight(.usageCalendar) != nil) }
    #expect(store.addInsight(.usageCalendar) == nil)
    #expect(store.menuPreferences.dashboardLayout.insights.count == 12)
    #expect(store.refreshingAccounts.isEmpty)
    let id = store.menuPreferences.dashboardLayout.insights[0].id
    store.removeInsight(id)
    #expect(store.addInsight(.weeklyPace) != nil)
    await store.shutdown()
}

@Test @MainActor func oneMoveSkipsHiddenAndFilteredCards() async throws {
    let store = AppStore(demo:true)
    let first = store.accounts[0].id
    let pace = try #require(store.addInsight(.weeklyPace,accountID:first))
    let burn = try #require(store.addInsight(.burnRate,accountID:first))
    let paceKey = "insight:" + pace.uuidString, burnKey = "insight:" + burn.uuidString
    store.setDashboardTileHidden("overview",hidden:true);store.setDashboardTileHidden("activity",hidden:true)
    store.moveDashboardTile(paceKey,offset:-1)
    var visible = store.menuPreferences.dashboardLayout.arranged(store.dashboardTileIDs)
    #expect(visible.firstIndex(of:paceKey) == 3)
    store.moveDashboardTile(burnKey,offset:-1,within:[paceKey,burnKey])
    visible = store.menuPreferences.dashboardLayout.arranged(store.dashboardTileIDs)
    #expect(visible.firstIndex(of:burnKey) == 3)
    #expect(store.menuPreferences.dashboardLayout.hidden == ["overview","activity"])
    await store.shutdown()
}
