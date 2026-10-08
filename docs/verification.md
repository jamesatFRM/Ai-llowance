# Preview verification

UsageBar 0.1.0 is a preview, not a production release. The downloadable app is ad-hoc signed, not Developer ID signed or notarized.

## Verified locally

- Apple Silicon release build with Swift 6.4, targeting macOS 14+.
- 30 Swift Testing tests: quota parsing, units, multiple windows, rejection of missing/malformed/cached reports, cost pagination, account isolation, process timeouts, credential handling, legacy settings restoration, identity propagation, polling boundaries, and provider backoff. The final local release run enabled the optional isolated dummy-Keychain round trip with `USAGEBAR_TEST_KEYCHAIN=1`.
- Real subscription reads for two Claude accounts and two Codex accounts, with separate email labels in the native UI.
- Native compact-menu layout checked using fictional sample accounts.
- Automatic reading timestamps advanced for all four accounts without clicking Refresh.
- Direct Claude usage with Claude Code 2.1.294 returned a successful JSON envelope with zero model turns and zero model cost. No conversation or persistent Terminal session was required.
- Legacy status-line migration preserved independent user changes and restored the previous setting when still owned by UsageBar.

## Integration boundaries

Claude uses its installed CLI's built-in `/usage` command, not an external published quota API. Its printable plan-row format may change. Unknown, incomplete, model-generated, cached, or rate-limited reports are rejected rather than converted into invented fresh usage.

Codex uses local app-server account and quota methods. The readings do not represent every ChatGPT feature. Provider reporting latency and rounding can differ from another provider surface.

Successful reads become due again after 60 seconds. A local timer checks deadlines every 15 seconds with tolerance; response time may extend the cadence. Opening the menu allows a healthy read after 30 seconds. Errors retain backoff, including provider Retry-After. Offline, sleeping, and paused states suppress reads.

## Not yet established

- A clean install and browser-login walkthrough on another person's Mac.
- Intel builds and the full range of supported macOS releases.
- Live organization API billing: adapters are verified with synthetic fixtures, not a supplied real admin key.
- Developer ID signing, notarization, independent security audit, and automatic updates.
- Remaining Claude API credit balances or Vercel Gateway balances.

GitHub Actions is configured to run tests and package the app on a fresh macOS runner. A workflow definition alone is not evidence that a run has passed; check the repository's actual checks before downloading a release.

## Prepared release artifact

The Apple Silicon ZIP passed a strict file allowlist, executable-permission and bundle-identity checks, sensitive-pattern checks, and a check for local machine paths. Archived executables match the packaged app that was opened and inspected natively. Public source was checked for real account identifiers, local home paths, and credential patterns. These focused checks do not constitute an independent security audit.

The repository and release archive are prepared locally. Public GitHub publishing and its first CI run are pending repository-owner selection.

## Current interface verification

The menu uses one overall weekly row per account, weekday reset labels, small email labels, and a smaller five-hour session row with a bold label when available. Model-specific weekly limits are tucked into Settings. An expired session does not invalidate an otherwise fresh weekly reading.

All 36 tests passed, including equal-weight averages, account filtering, missing/stale/error groups, backward-compatible settings, and allowance-color boundaries (30% normal, above 20% warning, at or below 20% critical). The release build, signature check, and strict archive checks passed.

Native UI inspection verified Light, Dark, and Automatic controls; transparent monochrome marks; compact account mode without names; account selection; provider averages; the combined average; pause/resume; and the smaller bold five-hour rows. The dropdown was absent after an outside click. Readings refreshed for both Claude accounts and both Codex accounts. These checks were on this Mac only, not a clean install or public CI run.

The current healthy-read scheduler uses a dispatch timer independent of AppKit event tracking. Manual refresh requests during a read are queued and remain subject to provider backoff. The earlier report of updates requiring Settings was not conclusively reproduced, so the scheduling fix is not proof of that report's root cause.
