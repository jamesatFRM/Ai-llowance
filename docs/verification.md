# Preview verification

Ai-llowance 0.1.0 is an ad-hoc signed, unnotarized preview, not a production release.

## GitHub update and local run — October 10, 2026

- Fresh validation: 75 fixture tests passed, including real network/heartbeat utility-queue delivery across a full 15-second monitoring cycle. This exposed and fixed a Swift actor-isolation startup crash; the callbacks explicitly cross to the main actor before touching UI state.
- This Mac's default SDK cache helper stalled and the native backend did not discover Swift Testing automatically. Validation used the native backend with the installed Testing framework supplied explicitly; no global toolchain settings or project build scripts changed.
- Release build, strict code-signature validation, and packaged-archive privacy/content checks passed. Installed and launched the matching signed build with account settings preserved byte-for-byte.
- Source changes go through the protected main branch's pull request and required macOS checks. The public v0.1.0 preview download remains unchanged; this is not a production release.

## Menu-bar display — October 10, 2026

- Unavailable readings now render as 0% in the actual menu-bar title, Settings preview, and share preview. The underlying missing/restricted state remains unchanged; hover/accessibility text and dropdown status still describe unavailability.
- Release build and strict signature verification passed using SwiftPM's native backend after the default backend's SDK cache helper stalled. Only this build's stalled processes were stopped; the project build script was not changed.
- Installed the signed local build with account settings preserved byte-for-byte. Visually verified the native Settings preview shows 0% for unavailable entries and retains the available account percentage.
- Current native account readback also confirms distinct personal/work Codex identities; the work account reports a provider restriction. The prior browser-reconnection gap is resolved on this Mac.
- This display update is installed locally and has not been published to the production/release download.

## Codex identity fix — October 9, 2026

- 74 fixture tests passed (54 core/provider and 20 application-flow tests). New coverage verifies distinct identity persistence, duplicate quota rejection, shared CLI account changes, and recovery without changing connection IDs or menu preferences.
- No credential extraction, additional polling, or model calls were added. Expected Codex emails are private connection metadata.
- Replaced the running local build and verified the native Settings UI: the personal Codex connection displays its real quota, and the mismatched second connection displays its expected email and a sign-in issue instead of a duplicate quota. Verified Use another browser profile prepares a pending link without opening the default browser, exposes Copy sign-in link, and shows the short additional-account instruction. Both Claude readings still work and menu preferences are preserved.
- At this October 9 checkpoint, the work account still required browser authorization. October 10 native readback above resolves that local account-verification gap. These changes have not been published to the production/release download.

## Verified locally — October 8, 2026

- Apple Silicon release build with Swift 6.4, targeting macOS 14+.
- **70 tests passed:** 54 core/provider tests and 16 application-flow tests. The local run included the optional disposable Keychain round trip. Tests cover parsing, account isolation, credential failures, process deadlines/cancellation, login origins, stale responses, safe persistence, polling/backoff, fictional export, and process-scoped telemetry opt-outs.
- Two Claude and two Codex subscription accounts read successfully in the native interface during local hardening; saved settings survived app replacement unchanged.
- Automatic refresh advanced all four accounts without manual Refresh; compact grouping, outside-click dismissal, pause/resume, and Light/Dark/Automatic controls were inspected.
- Claude Code 2.1.294 returned a successful `/usage` report with zero model turns and zero model cost. No conversation or persistent Terminal session was required.
- Fictional dark/light share images were generated from the actual dashboard rows and visually inspected.
- Current source, reachable Git history and archive checks found no real account identities, credential patterns or machine-specific paths. A source security review found no confirmed vulnerability; this is not an independent certification or proof of absence.

## Integration boundaries

Claude uses its installed CLI's built-in `/usage`, not a published external quota API. Unknown, incomplete, model-generated, cached or rate-limited reports are rejected. Codex uses local app-server account/quota methods, which do not represent every ChatGPT feature. Provider latency and rounding may differ from other surfaces.

Successful reads become due after 60 seconds; a coalescible timer checks every 15 seconds. Opening the menu allows a healthy read after 30 seconds. Errors retain backoff. Offline, sleeping and paused states suppress reads. Resource measurements and methodology are in the [hardening report](hardening-and-resources.md); they describe the measured earlier build, not every Mac or provider CLI version.

## Release verification

The package script verifies the signature, an exact archive-file allowlist, executable permissions, bundle identity, common sensitive patterns and local machine paths. GitHub Actions runs fixture tests, source/history privacy checks and packaging on a fresh macOS runner. Check the [actual CI runs](https://github.com/jamesatFRM/Ai-llowance/actions) and [release notes](https://github.com/jamesatFRM/Ai-llowance/releases/tag/v0.1.0) for the published revision and checks; a workflow definition alone is not a passing run.

## Not yet established

- A clean install and fresh browser-login walkthrough on another person's Mac.
- Intel binaries and the full range of supported macOS versions.
- Live organization API billing with real admin keys; adapters are fixture-tested.
- Developer ID signing, notarization, independent security audit or automatic updates.
- Exhaustive provider-CLI telemetry, cache/log retention or managed-policy behavior. See [Privacy](../PRIVACY.md).
- Claude API credit balances, Vercel Gateway balances, Gemini or Grok support.
