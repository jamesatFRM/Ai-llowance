# Ai-llowance 0.6.3 — Clear limits. Reliable charts.

Build 248 improves usage accuracy, chart consistency and settings reliability.

- **Keep different limits separate.** Grouped menu readings no longer average weekly and 5-hour allowances together. Recent-usage graphs keep one consistent metric instead of creating false spikes when a weekly reading is missing.
- **Charts that agree with their totals.** Comparisons use the same matched days as their summaries. API spending lines break at UTC billing-month boundaries. Rings and gauges match the account headline's percentage labels.
- **Settings that keep your choices.** Renaming an account preserves its separate colors. Changing selected color targets leaves other saved colors intact, with explicit actions for applying one color everywhere or restoring provider colors.
- **Clearer account states.** A 5-hour-only account identifies the missing weekly limit correctly. Unlimited accounts show an unlimited state without inventing percentages or describing a verified reading as missing.
- **A more consistent dashboard and dropdown.** Expanded cards align across chart styles. Expanded dropdown history shows the last 24 hours with at most 120 plotted points; full saved history remains available. VoiceOver includes displayed account emails and recent-usage graph information.

No new background polling, timers or dependencies. Existing account settings and stored history are preserved; daily summaries retain the existing 400-day retention.

Signed and notarized for Apple silicon and Intel Macs on macOS 14 or later. Open Settings → Updates → Check for Updates, then Install and Relaunch.

Release artwork uses illustrative UI, not an actual app screenshot.
