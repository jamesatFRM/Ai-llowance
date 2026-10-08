# Hardening and resource verification

October 8, 2026. Measurements taken before public preview publication, at source revision `ba1dcdee`. Not a production certification.

## Scope and outcome

Reviewed the native app, menu summaries, settings persistence, connection flows, Claude and Codex adapters, API cost reporting, Keychain wrapper, legacy bridge, and release packaging. This is an engineering hardening pass, not an independent security certification or a guarantee against every failure.

The installed build successfully read the two existing Claude accounts and two existing Codex accounts. Their saved account/preferences file remained byte-for-byte unchanged during replacement. No real credentials were expired, deleted, or signed out. The dropdown and Settings preview showed the same provider order: Claude accounts together, then OpenAI accounts. Order within each provider and the user's compact, all-accounts selection were preserved.

**68 tests passed:** 52 core/provider tests and 16 application-flow tests, including the opt-in disposable Keychain round trip. Release build, code-signature verification, and archive privacy checks passed.

## Corrections and verification

| Area | Change / evidence |
| --- | --- |
| Persisted and provider data | Decoded quotas now use the same percentage, reset-date, duration, and field-size validation as newly created quotas. Oversized saved settings and duplicate account IDs fail closed, preserving the original file. |
| File privacy and failures | Private temporary files are created with 0600/0700 permissions before writing, flushed, then atomically renamed. Tests cover replacement, permissions, bounded reads, failed rename cleanup, and a destination symlink without overwriting its target. |
| Account removal | Verify writable settings before changing provider credentials. Corrupt settings cannot cause removal to start. Credential storage and account metadata are separate systems, so a later disk failure after provider logout can still require reconnecting. |
| Lifecycle | Quit cancels pending reads, Codex sign-in, and initial Claude connection checks, then waits for their cleanup. Codex stop completes its termination fallback on the worker instead of scheduling a callback that could be lost at app exit. |
| Honest allowance display | A provider-reported usage/credit restriction makes the menu summary unavailable and shows a warning in account details. It cannot be averaged into an apparently healthy allowance. |
| API cost reporting | Invalid/overflowed totals are rejected both within a response and across pages. Existing tests cover monetary units, complete pagination, repeated cursors, safe HTTP errors, and Retry-After. No credit-balance support is inferred. |
| Resource work | Smaller cached icon mask, software icon conversion, and no rebuilding identical menu text every heartbeat. Serial, short-lived provider reads and backoff remain. |
| Share privacy | Dark/light PNG export uses fictional in-memory accounts and real dashboard rows. A regression test confirms demo mode does not read providers or alter the saved settings file. Both exports were visually inspected. |

The existing connection suite also exercises malformed/oversized output, hung or failed children, cancellation, expired authentication, rejected login origins, early login notifications, isolated profiles, inherited API-key exclusion, stale results after reconnect, failed browser/Terminal launch, abandoned sign-in, missing data, duplicate email warnings, offline/pause suppression, and preservation of user-edited Claude settings.

## Resource measurement

Measured on an Apple M4 Max running macOS 27.0.1, with four connected subscription accounts and automatic refresh enabled. Settings and the dropdown were dismissed before sampling. The 154.34-second run captured two automatic refresh rounds, with 272 samples at approximately half-second intervals. No provider child was active at either boundary.

| Metric | Observed |
| --- | ---: |
| App physical footprint, median / sampled peak | 48.89 / 49.02 MiB |
| App CPU time / average of one core | 0.308 seconds / 0.199% |
| Provider child CPU time | 9.227 seconds |
| App + completed provider children, average of one core | 6.178% |
| App + live provider children, sampled physical footprint peak | 273.56 MiB |
| App RSS median / combined RSS sampled peak | 83.77 / 493.38 MiB |
| Peak live provider children observed | 1 |
| App interrupt wakeups | 230 (about 1.49/sec; not a complete energy metric) |
| App disk reads / writes during sample | 2.29 MiB / 0 bytes |
| Local app bundle / compressed ZIP | 2.9 MiB / 0.76 MiB |

Method: macOS `proc_pid_rusage` physical-footprint and process/terminated-child CPU counters, plus `ps` process ancestry. CPU ticks were converted using this Mac's `mach_timebase_info` ratio (125/3 nanoseconds per tick), and cross-checked against `ps` cumulative CPU. Apple's [XNU accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) fills the resource counters from task power information and physical footprint; its [Recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md) describes the CPU accounting and Mach-time representation.

The combined footprint sums per-process charges and is not a system-wide unique-memory measurement; RSS can count shared pages and is included separately, not presented as the app's private memory. Sampling can miss very brief peaks. Child CPU includes completed children during the window, avoiding the undercount from merely sampling their lifetimes. CLI/provider traffic, OS helper services, long-duration leaks, battery drain, and energy impact were not exhaustively measured. This is a short local measurement under ordinary desktop activity, not a controlled cross-device benchmark.

A preliminary 99.72-second run of the previous build reported 95.4 MiB app RSS and about 0.28% of one core, with a 449.6 MiB combined RSS peak. That run used different UI conditions, so it is not a controlled before/after performance comparison.

The lightweight claim applies most strongly to the native app while idle. Refresh invokes the installed provider CLIs, whose memory and CPU are material and version-dependent. Do not advertise the whole setup as extremely lightweight. No Electron, embedded browser, persistent inference process, analytics service, or app-owned always-running CLI daemon is bundled.

## Limits that remain

- Claude's printable `/usage` report is a version-dependent CLI integration, not a guaranteed external quota API. A provider update can require an adapter update. Unrecognized or cached reports remain visibly unavailable/stale.
- Provider CLI startup is the main refresh resource cost; additional accounts increase work. The app preserves approximately one-minute healthy refresh and provider backoff.
- Claude's interactive login belongs to Terminal. Stopping the app's waiting state does not close that Terminal session. Claude sign-out remains explicit and CLI-managed.
- Tests use isolated fake provider processes for failure paths. Fresh SSO on another Mac, real locked-Keychain behavior, actual machine sleep/wake cycles, Intel, and every supported macOS version were not certified in this pass. API spending was fixture-tested, not exercised with live organization admin credentials.
- This preview is ad-hoc signed, not Developer ID signed or notarized. See the repository release page for current public preview availability.
