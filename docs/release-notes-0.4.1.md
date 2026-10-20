# Ai-llowance 0.4.1 — A more refined workspace

- History is now the dashboard home, with compact top navigation, a chart-first responsive grid of up to four cards per row, and a slim header with full-width content.
- Charts use a clean stroke, subtle fill, and latest-reading marker. Missing data, changed quota windows, restored allowance, and billing rollovers stay separate instead of being joined into misleading lines.
- Connected Claude and Codex accounts hide their setup prompt; sign-in help remains available when needed.
- The menu popover is kept within the active screen’s usable bounds when it opens or resizes. Its height adapts to the screen and routine launch notices no longer crowd it.
- The 24-hour / seven-day history filter is a larger segmented control.

History stays local and bounded. No new polling, background service, or dependency was added.

Release artwork is an illustration, not an application screenshot.

The dashboard and menu share navy surfaces, mint OpenAI accents, warm Claude accents, and amber attention states.

- Account tiles now combine current status, identity, allowance, reset timing, history, and direct actions.
- A rolling seven-day hourly heatmap shows relative recorded subscription allowance consumption, with missing intervals distinguished from measured quiet periods. This is not a measure of coding hours; API dollars are excluded.

- Native grouped settings add Dock visibility, refresh interval choices, and a feedback link alongside launch-at-login and notifications.
- Rename accounts and choose a custom accent for the menu, dashboard, and/or graph.
- Optional menu allowance colors progress from white at 100% through cool and warm colors to red at 0%. Unavailable readings stay neutral.
