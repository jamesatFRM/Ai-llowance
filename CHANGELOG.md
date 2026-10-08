# Changelog

## 0.1.0 — Preview

- Renamed the app to Ai-llowance. Existing connections and preferences keep their original storage and Keychain identities.

- Native macOS menu bar interface with compact provider groups.
- Multiple Claude Code and OpenAI Codex subscription accounts with small email labels.
- Weekly remaining quota, reset weekdays, one global refresh status, and clear unavailable/stale states. Five-hour session limits appear underneath and do not affect the menu-bar percentage.
- Automatic refresh about once a minute, manual refresh, pause, and provider backoff.
- Browser-assisted account setup through installed provider CLIs.
- Optional organization API spending, kept separate from subscription limits.
- Keychain storage for API keys and no third-party runtime dependencies.

- Redesigned Settings, direct pause/quit icons, and dismiss-on-outside-click menu.
- One weekly row per account, signed-in emails, smaller five-hour readings, and shared white/yellow/red allowance bars.
- Official provider icons; combined, provider, or individual menu-bar summaries with selected accounts and optional account names.
- Equal-weight averages by default, with transparent unavailable groups; background polling independent of UI tracking and queued manual refreshes.
- Light, Dark, and Automatic appearance, monochrome transparent provider marks, and bold secondary session labels.

This preview does not include Claude API credit balances, Vercel Gateway balances, Google/Gemini, Grok, an automatic updater, or a notarized installer. Claude's printable usage format is version-dependent. Intel binaries and compatibility across all supported macOS versions have not been verified.
