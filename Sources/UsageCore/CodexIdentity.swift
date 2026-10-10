import Foundation

/// Bind a connection to its verified provider email. Never substitute a current CLI
/// account for a previously connected account or count a second connection to it.
public enum CodexIdentity {
    public static func normalized(_ identity: String?) -> String? {
        guard let value = identity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        return value
    }
    public static func validate(_ snapshot: Snapshot, for account: Account,
                                accounts: [Account], snapshots: [UUID: Snapshot]) throws -> String {
        guard let actual = normalized(snapshot.identity) else { throw UsageError.authentication }
        if let expected = normalized(account.expectedIdentity), expected != actual {
            throw UsageError.accountChanged(expected)
        }
        if let other = accounts.first(where: {
            $0.id != account.id && $0.kind == .codex
                && normalized($0.expectedIdentity ?? snapshots[$0.id]?.identity) == actual
        }) { throw UsageError.duplicateAccount(other.name) }
        return actual
    }
}
