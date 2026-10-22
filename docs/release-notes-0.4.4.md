# Ai-llowance 0.4.4 · Build 227

- Weekly allowance is the primary number, with a separately labeled rolling five-hour allowance in the menu bar and dashboard. Readiness and alerts still respect exhausted session limits.
- Verified usage history survives reconnecting the same account and app restarts/updates. A reconnect clears the current reading without deleting its verified historical samples.
- Charts now retain up to seven days of five-minute readings, instead of only 96 samples.
- Clear “Reconnect required” status and a direct account action in Usage, plus an explanation of the one-time Claude connection migration.

Older shared Claude connections require one reconnect with the saved email. Unverified historical readings from those shared connections cannot safely be restored. History stays local to this Mac; removing an account or replacing its API key starts a new history. Retention is a rolling seven days, not an unlimited archive.

Developer ID signed and notarized by Apple. Available through Check for Updates.
