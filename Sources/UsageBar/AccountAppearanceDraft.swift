import UsageCore

/// Editing a name or target must not silently replace other saved accents.
struct AccountAppearanceDraft {
    var name: String
    var menu: Bool
    var dashboard: Bool
    var graph: Bool
    private(set) var colorHex: String
    private let initialColorHex: String
    private var forceSameColor = false
    private var resetColors = false
    private let originalMenu: String?
    private let originalDashboard: String?
    private let originalGraph: String?

    init(account: Account, fallbackHex: String) {
        name = account.name
        originalMenu = account.menuColorHex; originalDashboard = account.dashboardColorHex; originalGraph = account.graphColorHex
        menu = originalMenu != nil; dashboard = originalDashboard != nil; graph = originalGraph != nil
        colorHex = originalGraph ?? originalDashboard ?? originalMenu ?? fallbackHex
        initialColorHex = colorHex
    }
    mutating func chooseColor(_ hex: String) { colorHex = hex }
    mutating func applyEverywhere() { menu = true; dashboard = true; graph = true; forceSameColor = true }
    mutating func useProviderColors() { menu = false; dashboard = false; graph = false; resetColors = true; forceSameColor = false }
    private var usesAccent: Bool { forceSameColor || resetColors || colorHex.lowercased() != initialColorHex.lowercased() }
    private func color(selected: Bool, original: String?) -> String? {
        if selected { return usesAccent ? colorHex : original ?? colorHex }
        return resetColors ? nil : original
    }
    var menuHex: String? { color(selected: menu, original: originalMenu) }
    var dashboardHex: String? { color(selected: dashboard, original: originalDashboard) }
    var graphHex: String? { color(selected: graph, original: originalGraph) }
}
