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
