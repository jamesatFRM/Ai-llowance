import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    private var controller: SPUStandardUpdaterController?
    private var started = false
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    // Missing metadata remains a preview, including older bundles and local SwiftPM builds.
    static var isPreview: Bool { (Bundle.main.object(forInfoDictionaryKey: "AILPreviewBuild") as? Bool) != false }
    static var versionLabel: String { isPreview ? "Preview · \(version)" : version }

    init(enabled: Bool) {
        // Fixture tests and share previews never start updater networking.
        guard enabled, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }
    func start() {
        guard !started, let controller else { return }
        started = true
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main).assign(to: &$automaticChecks)
    }
    func check() {
        guard canCheck, let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}
