# Account connection pressure test

Date: October 8, 2026. Status: verified locally; not a public or production release.

## Outcome

58 tests passed: 46 provider/core tests and 12 application connection-flow tests. The opt-in dummy-Keychain test ran with a unique service and removed its test items. The release build, signing verification, and archive checks passed. After installing the updated build, the native Settings UI showed fresh readings and separate emails for the two existing Claude accounts and two existing Codex accounts. The real account/preferences file was byte-for-byte unchanged during replacement. No real account was signed out or removed.

## Problems corrected

| Trigger | Previous behavior | Current behavior and evidence |
| --- | --- | --- |
| Claude auth check fails temporarily | Failure could be treated as logged out and launch a new login | Failure remains visible, with no account creation or login launch; application test |
| First Claude connection finds an API-billed or logged-out CLI | Login could replace the current CLI identity | Subscription setup uses a separate profile; existing settings preserved; application test |
| Reconnect while a read is in flight | Old result could restore an obsolete connection state | Per-account attempt identity rejects superseded responses; controlled delayed-response test |
| Authentication expires after a successful reading | Existing data could hide the main recovery action | Sign in remains visible with last-known data; API credentials offer Replace key; application test |
| Browser or Terminal does not launch, or sign-in is abandoned | Unclear waiting/recovery state | Explicit progress, launch failure, retry, Codex cancellation/timeout, and Claude completion/timeout handling; provider and application tests |
| Claude CLI closes stdout but hangs, emits excessive output, or exits unsuccessfully | Partial output could be mistaken for a completed command | Bounded output, cancellation, full process deadline, and exit-status validation; subprocess tests |
| Separate accounts or repeated Add clicks | Ambiguous labels and duplicate setup possible | Unique labels, isolated provider profiles, pending-login guards, and same-email warning; tests |
| App-owned Claude profile has plaintext credential fallback | Later reads could reuse that fallback | Read is rejected before invoking the CLI; fixture test |
| A provider fails or rate-limits requests | Recovery must preserve other accounts and provider backoff | Other accounts still read; retry does not override rate-limit backoff; application and core tests |

Other checks cover early/out-of-order Codex login notifications, login-ID matching, rejected login origins, browser-open failures, API-key environment isolation, malformed reports, corrupt account settings, paused/offline suppression, and preservation of user-modified Claude settings.

## User experience

- Add account remains usable during ordinary refreshes. Concurrent login attempts are guarded.
- Missing provider software has installation and location controls directly under the provider section.
- Claude successful login is detected by a private completion result on the normal local heartbeat, usually within 15 seconds, followed by a fresh usage read. Only exit status is saved; no login URL or credentials are stored in the result.
- Claude's Terminal owns its sign-in process. Stop waiting stops the app's waiting state; the user must close that Terminal before retrying. It does not claim to terminate the provider's interactive login.
- Codex login cancellation closes its owned app-server connection. It has a five-minute deadline; unfinished Claude waiting has a ten-minute deadline.
- Existing Codex CLI profiles retain externally managed authentication and provide Check sign-in after reauthentication.
- Duplicate email is a warning, not automatic merging: one email may represent more than one organization or plan.

## Limits of this verification

Failure cases used isolated executable fixtures and app data, not intentional corruption or expiration of real credentials. The live check validated existing authenticated accounts after the change. A fresh browser SSO/consent walkthrough on another Mac, a genuinely locked login Keychain, and alternate corporate/managed environments remain unverified. Provider CLIs still own authentication; Claude's printable /usage format is version-dependent. This is not a claim of universal provider or macOS compatibility.
