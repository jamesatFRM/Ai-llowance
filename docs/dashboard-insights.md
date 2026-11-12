# Optional dashboard insights

Six optional views can be added from **Usage → Customize dashboard**. Existing dashboards receive no additional cards automatically. The visual gallery has illustrative thumbnails, and **Your layout** shows all cards, including hidden ones.

Each insight keeps its account, compatible chart style, time period, width and collapse state. Cards can be reordered with the layout editor's keyboard-accessible arrows or the insight's menu. Hiding a card keeps its connection and readings; removing an insight removes only the card. Restoring the default layout preserves connections, account names, colors and individual account chart choices.

## Metrics

- **Weekly pace:** current weekly-cycle remaining allowance, an even-use guide and an explicitly estimated allowance at reset. A forecast needs a current reading and at least six hours of continuous measured intervals. It never mixes a five-hour window into a weekly percentage.
- **Unused allowance:** the last actual reading before an observed weekly reset. The observation's distance from reset is shown; the value is not presented as exact end-of-cycle usage. Readings more than 24 hours before reset are excluded. Up to 64 closing observations are kept for the existing 400-day retention.
- **Limit pressure:** separate current weekly and five-hour allowances, with optional history lines and the count of recent readings at or below 10%. Unsupported windows are omitted, rather than fabricated.
- **Burn rate:** observed consumption per measured hour, in one-hour or six-hour buckets. API accounts use dollars; subscription cards explicitly select weekly or five-hour allowance points. Refills, billing-period boundaries and unmeasured gaps do not create consumption.
- **Usage calendar:** daily observed consumption, measured active days and the longest observed streak, using UTC daily summaries. Outlined cells are unmeasured, while measured zero-use days have a fill. Long bar views use weekly totals.
- **Credit runway:** current API credit balance, observed spending and an approximate runway at the measured spending rate. It needs three completed measured days and twelve measured hours for an estimate. Top-ups are excluded. Subscription percentages and month-to-date API spending are never treated as credit balances.

Forecasts pause on cached readings or connection problems, while measured history stays available. Sparse history produces an explanation, not a made-up zero or forecast. Every insight is bound to an explicit account ID; removing an account never silently assigns its card to a different account.

## Footprint and persistence

All calculations run on this Mac using the existing provider refreshes. There are no additional dependencies, polling loops, timers, external analytics calls or credential changes. A dashboard can contain at most 12 optional insight cards. Allowance lines are bounded to 180 plotted observations and credit lines to 160; calendar views use at most 360 daily summaries.

Preferences are an optional addition to `MenuPreferences`. Old settings keep their default layout, and unknown future insight kinds are skipped. Reset-cycle summaries are optional fields in the existing identity-bound reading cache; existing readings and daily summaries are preserved. Tests cover legacy settings, account isolation, independent metrics, resets, gaps, credit top-ups, forecast sufficiency, cache compaction, reconnection and preference persistence.

The development preview is a separate app with sample data and disabled updater networking. These additions are not published until a signed, notarized release is placed on the live Sparkle feed.
