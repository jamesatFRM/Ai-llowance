import AppKit
import Foundation
import Testing
import UsageCore
@testable import UsageBar

@MainActor @Test func appearanceSavePersistsNameAndIndependentTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Appearance-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Original", kind: .codex)
    store.accounts = [account]
    #expect(store.setAccountAppearance(account, name: "Personal", menu: "FF0033", dashboard: nil, graph: "33AAFF"))
    let loaded = AppStore(root: root, monitor: false)
    #expect(loaded.accounts.first?.name == "Personal")
    #expect(loaded.accounts.first?.menuColorHex == "FF0033")
    #expect(loaded.accounts.first?.dashboardColorHex == nil)
    #expect(loaded.accounts.first?.graphColorHex == "33AAFF")
    #expect(!store.setAccountAppearance(account, name: " ", menu: nil, dashboard: nil, graph: nil))
    #expect(!store.setAccountAppearance(account, name: "Personal", menu: "bad color", dashboard: nil, graph: nil))
    await store.shutdown(); await loaded.shutdown()
}
@MainActor @Test func allowanceColorsClampAndHexRejectsInvalidValues() {
    #expect(NSColor.allowance(0) == NSColor.systemRed)
    #expect(NSColor.allowance(100) == NSColor.white)
    #expect(NSColor.allowance(-50) == NSColor.systemRed)
    #expect(NSColor.allowance(150) == NSColor.white)
    #expect(NSColor.accountHex("not hex") == nil)
    #expect(NSColor.accountHex("33AAFF") != nil)
}

@MainActor @Test func switchingThemesPreservesAccountsAndMenuChoicesAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Theme-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let account = Account(name: "Work", kind: .codex)
    store.accounts = [account]
    store.setMenuDisplay(.byProvider)
    store.setMenuAggregation(.lowest)
    store.setAllMenuAccounts(false)
    store.setMenuAccount(account, included: true)
    for theme in [AppTheme.light, .dark, .automatic, .dark, .automatic] {
        store.setTheme(theme)
        let reloaded = AppStore(root: root, monitor: false)
        #expect(reloaded.menuPreferences.theme == theme)
        #expect(reloaded.menuPreferences.display == .byProvider)
        #expect(reloaded.menuPreferences.aggregation == .lowest)
        #expect(reloaded.menuPreferences.selectedAccountIDs == [account.id])
        #expect(reloaded.accounts.first?.id == account.id)
        await reloaded.shutdown()
    }
    await store.shutdown()
}

@MainActor @Test func menuOrderPersistsAcrossRestartAndResets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MenuOrder-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    let a = Account(name: "Claude", kind: .claudeCode)
    let b = Account(name: "Codex", kind: .codex)
    store.accounts = [a, b]
    store.moveMenuAccount(b.id, offset: -1)
    let loaded = AppStore(root: root, monitor: false)
    #expect(loaded.orderedMenuAccounts.map(\.id) == [b.id, a.id])
    loaded.moveMenuAccount(b.id, offset: -1)
    #expect(loaded.orderedMenuAccounts.map(\.id) == [b.id, a.id])
    loaded.resetMenuAccountOrder()
    #expect(loaded.orderedMenuAccounts.map(\.id) == [a.id, b.id])
    await store.shutdown(); await loaded.shutdown()
}

@MainActor @Test func liquidGlassDefaultsOnAndOpaqueChoiceSurvivesRestart() async throws {
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8)).liquidGlass)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glass-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    #expect(store.menuPreferences.liquidGlass)
    store.setLiquidGlass(false)
    let loaded = AppStore(root: root, monitor: false)
    #expect(!loaded.menuPreferences.liquidGlass)
    loaded.setLiquidGlass(true)
    let restored = AppStore(root: root, monitor: false)
    #expect(restored.menuPreferences.liquidGlass)
    await store.shutdown(); await loaded.shutdown(); await restored.shutdown()
}

@MainActor @Test func glassLayerDoesNotCaptureClicksOrWindowDrags() {
    let glass = PassiveGlassView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    #expect(glass.hitTest(NSPoint(x: 100, y: 100)) == nil)
    #expect(!glass.mouseDownCanMoveWindow)
    #expect(!glass.acceptsFirstResponder)
}

@MainActor @Test func transparencyPreferencesAreIndependentAndPersisted() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Transparency-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(defaults.dashboardTransparency == 0.75)
    #expect(defaults.dropdownTransparency == 0.75)
    let store = AppStore(root: root, monitor: false)
    store.setDashboardTransparency(0.25)
    store.setDropdownTransparency(0.9)
    let loaded = AppStore(root: root, monitor: false)
    #expect(loaded.menuPreferences.dashboardTransparency == 0.25)
    #expect(loaded.menuPreferences.dropdownTransparency == 0.9)
    store.setDashboardTransparency(-1)
    store.setDropdownTransparency(2)
    #expect(store.menuPreferences.dashboardTransparency == 0)
    #expect(store.menuPreferences.dropdownTransparency == 1)
    store.setDashboardTransparency(.nan)
    #expect(store.menuPreferences.dashboardTransparency == 0)
    await store.shutdown(); await loaded.shutdown()
}

@MainActor @Test func unchangedPreferencesDoNotRewriteSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnchangedSettings-\(UUID().uuidString)")
    try Paths.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(root: root, monitor: false)
    store.setDashboardTransparency(0.5)
    let file = root.appendingPathComponent("accounts.json")
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    store.setDashboardTransparency(0.5)
    let after = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
    await store.shutdown()
}
