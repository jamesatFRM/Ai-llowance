# Ai-llowance 0.4.3 — Account isolation and smoother charts

- Claude tracking now uses a separate sign-in for each connected email. Switching accounts in Claude Desktop does not select Ai-llowance’s connection.
- Older shared Claude connections require a one-time reconnect with the saved email. Account names and colors are preserved. Old unverified Claude readings/history are not reused; new verified readings start fresh history.
- Codex rejects readings interrupted by an account-change notification, even if the email switches back before the read finishes.
- Replacing an API key prevents cached readings from the previous key from returning after restart.
- Individual account charts fill the dashboard, up to four per row, with smoother trends and clearer line glow. Comparison mode has been removed. Real gaps and resets remain visible.
- Fixed account setup showing an older connection as a newly completed sign-in; improved chart ranges and rejected future-dated readings.

Requires macOS 14 or later. Claude, Codex and Copilot require their respective CLIs. Copilot currently supports the existing CLI account only. API balances and spending remain separate from subscription allowances.

Validation: 160 Swift tests, 13 release-integrity tests, and local preview build passed. Account-switch regressions use controlled fixtures; live switching on every customer Mac has not been verified.
