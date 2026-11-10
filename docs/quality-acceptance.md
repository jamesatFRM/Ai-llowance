# Quality release gate

Run `bash scripts/quality-check.sh` locally. It runs privacy-guard self-tests, feed tooling tests and both Swift test targets without using GitHub Actions minutes. Fake providers and private temporary roots exercise failures; no real account is signed out.

## Core workflows

| Workflow | Automated evidence | Native acceptance before a public release |
| --- | --- | --- |
| Connect two accounts | ConnectionFlow, AccountIsolation, CodexIdentity, SetupAndCache | Add a distinct account, verify the email and first reading, cancel another sign-in and retry. Verify both readings after switching in the provider desktop app. |
| Understand weekly / 5-hour | QualityContract, MenuSummary, ConnectionPresentation | Compare the menu, dropdown, Usage card and expanded limits. Missing is not zero. A reported weekly-only plan never gets an invented short window. |
| Lose network / recover | StoreReliability, ReadingIntegrityRegression | Disconnect and reconnect networking. Last-known values keep their observation time. One provider must not block another. Never bypass Retry-After. |
| Sleep / wake / pause | VisibilityCadence, StoreReliability | Sleep/wake a real Mac; confirm refresh resumes. Pause and hide the app; confirm no repeated provider traffic. |
| Update / preserve data | QualityWorkflow, LongHistory, ResetReminder | Install the signed release over an earlier supported build through Sparkle. Verify identities, order, colors, theme, reminder rules and history. Local restart tests alone do not prove this. |
| Explore history | ConsumptionHistory, QualityContract, HistorySeries | Check all seven ranges, both window choices, partial coverage, measured zero and missing intervals. Readings/plan points must not be presented as tokens, coding hours or equivalent account capacities. |
| Get support | QualityContract diagnostics allowlist tests | Review and copy diagnostics. Check that no email, nickname, path, key, usage value or raw provider output appears. Nothing is submitted automatically. |
| Use the Mac UI | AccountGridLayout, LayoutPreview | Keyboard navigation, Command-comma, Command-W and Command-M; VoiceOver labels; Light/Dark/Automatic; Reduce Motion, Reduce Transparency and increased contrast. Test window drag, resize, close, minimize and reopening. |

## Resource checks

- Retained history is bounded at 4,096 observations and 366 days of daily summaries per account. Verify with a populated one-year fixture.
- Chart rendering is bounded to 360 actual observations before smoothing; exact hover uses original samples. Segment IDs keep resets and gaps disconnected. Bar views are bounded to 24/28 actual bucket readings.
- Startup loads each account cache once for its reading, history and summaries. Cache persistence runs on a utility task.
- Dashboard chart contents unload on hide, close or minimize. Navigation state remains in the root view. No new background timers or polling are added.
- Run `python3 scripts/measure-footprint.py --pid PID --seconds 120 --interval 1` with the UI hidden, then visible. Record app and child CPU separately. Include a real refresh round and CLI startup peaks before claiming end-to-end resource performance.
- Resource objectives for this pass: near-zero idle app CPU, no persistent provider child, bounded memory across repeated show/hide cycles, and no work proportional to unbounded history. Record observed values; do not turn objectives into measured claims.

## Release boundary

A local preview is not production. A public update requires Developer ID signing, approved notarization, signed appcast publication, archive/feed verification, and an installed older build discovering and installing it. Include new versioned promotional artwork and its prompt with every public release.
