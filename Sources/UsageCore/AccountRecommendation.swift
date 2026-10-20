import Foundation

/// Compare only verified subscriptions within one provider. Never infer availability from a cache.
public enum AccountRecommendation {
    public static func best(kind: ConnectionKind, accounts: [Account], snapshots: [UUID: Snapshot],
                            unavailable: Set<UUID>, now: Date) -> Account? {
        guard kind == .claudeCode || kind == .codex else { return nil }
        let duplicates = duplicateSubscriptionAccountIDs(in: accounts, snapshots: snapshots)
        let candidates = accounts.filter { account in
            guard account.kind == kind, account.enabled, !unavailable.contains(account.id),
                  !duplicates.contains(account.id), let snapshot = snapshots[account.id],
                  let identity = CodexIdentity.normalized(account.expectedIdentity),
                  identity == CodexIdentity.normalized(snapshot.identity) else { return false }
            let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: kind, now: now)
            return [.ready, .low, .unlimited].contains(status.state)
        }
        return candidates.sorted { lhs, rhs in
            func score(_ account: Account) -> Double {
                let snapshot = snapshots[account.id]!
                return snapshot.unlimited == true && snapshot.applicableWindows(for: kind).isEmpty
                    ? 101 : (snapshot.limitingWindow(for: kind)?.remainingPercent ?? -1)
            }
            return score(lhs) == score(rhs) ? lhs.id.uuidString < rhs.id.uuidString : score(lhs) > score(rhs)
        }.first
    }
}
