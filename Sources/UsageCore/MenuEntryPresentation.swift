import Foundation

/// Shared by the actual status item and its Settings preview.
public enum MenuEntryPresentation {
    public static func value(_ entry: MenuEntry, preferences: MenuPreferences) -> String {
        if entry.isBalance { return entry.balanceUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) ?? "—" }
        let value = entry.isUnlimited ? "∞" : entry.remainingPercent.map { "\(Int($0))%" } ?? "—"
        guard entry.accountCount > 1, preferences.display != .byAccount else { return value }
        return value + (preferences.aggregation == .average ? " avg" : " lowest")
    }
    public static func title(_ entry: MenuEntry, preferences: MenuPreferences) -> String {
        let name = preferences.showAccountNames && (preferences.display == .byAccount || entry.isBalance) ? "\(String(entry.label.prefix(12))) " : ""
        return name + value(entry, preferences: preferences)
    }
}
