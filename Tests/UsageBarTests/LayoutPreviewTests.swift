import AppKit
import SwiftUI
import Testing
@testable import UsageBar

/// Opt-in visual regression matrix. Uses only in-memory accounts and never signs in.
/// Run separately: AIL_LAYOUT_PREVIEWS=/tmp/layouts bash scripts/test.sh --filter exportAccountLayoutMatrix
/// AppKit rendering occupies the main actor; do not combine with timing-sensitive store tests.
@MainActor @Test func exportAccountLayoutMatrix() throws {
    guard let path = ProcessInfo.processInfo.environment["AIL_LAYOUT_PREVIEWS"] else { return }
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func capture<V: View>(_ view: V, size: NSSize, name: String) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(size)
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
    for count in 1...10 {
        let store = AppStore(demo: true, demoAccountCount: count)
        for width in [760, 1080, 1440] {
            try capture(AccountsView(store: store, showMenu: {}), size: NSSize(width: width, height: 1100), name: "dashboard-\(count)-\(width)")
        }
        for height in [400, 620] {
            try capture(Dashboard(store: store, maximumHeight: CGFloat(height), manage: {}), size: NSSize(width: 350, height: height), name: "dropdown-\(count)-\(height)")
        }
    }
}
