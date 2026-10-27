# Ai-llowance 0.4.8 (build 231)

- Weekly and 5-hour allowances have separate labels and reset times. Session-only readings are clearly identified.
- Connection status distinguishes saved readings, offline connections, timeouts, provider delays, and accounts that need reconnecting.
- Accounts refresh independently with two bounded workers, so a slow provider does not hold up every reading. First-time identity checks remain ordered within each provider.
- Account cards use aligned quota columns, compact charts, and clear recovery actions.
- Network recovery retries interrupted checks while respecting provider rate limits.
- History save failures now display a notice without discarding live usage.

Existing accounts, preferences, and usage history are preserved. All checks ran locally; no GitHub Actions minutes were used.
