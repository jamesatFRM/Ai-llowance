# Privacy

Ai-llowance runs locally on your Mac. There is no Ai-llowance backend, analytics service, advertising, or cloud sync. Application update checks use GitHub as described below. The maintainer does not receive your account identities, usage, credentials, or diagnostic logs from the app.

## What leaves your Mac

Subscription checks use the installed Claude Code, Codex, Copilot, and Grok CLIs, which contact their providers. Optional API spending, credit, and budget checks send your key directly to the selected provider's fixed official HTTPS endpoint. xAI requests also include the team ID you enter. Login and dashboard links open provider pages in your browser. These services have their own privacy and retention policies.

Grok checks use only CLI initialization, non-secret account information, and unified billing. The connection stores the email and workspace ID to detect account changes. Grok manages its own credentials, caches, logs, and startup behavior; Ai-llowance does not read or copy its tokens.

Ai-llowance requests no model responses or conversation history. Claude's local `/usage` command may itself inspect local activity to prepare its report; Ai-llowance keeps only recognized plan limits and rejects reports with model turns or model cost. This is a version-dependent CLI integration.

For processes it starts, Ai-llowance sets Claude's `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`, and Codex's `analytics.enabled=false` and `feedback.enabled=false`. These process-scoped settings do not change your other CLI sessions or stop necessary authentication and quota traffic. Provider implementations and managed policies remain outside this app's control. See the official [Claude data-use documentation](https://code.claude.com/docs/en/data-usage) and [Codex configuration reference](https://developers.openai.com/codex/config-reference/).

## What stays on your Mac

| Data | Storage |
|---|---|
| Account nicknames, connection choices, preferences | Private files under `~/Library/Application Support/UsageBar` |
| Expected subscription identity | Saved privately with connection settings to detect account changes and duplicate accounts |
| Latest signed-in identity and reading | Private cache, bounded to 2 MiB per account including history; original observation time is preserved |
| Allowance, credits, or spending history | At most 4,096 observations per account: seven days of detail, then actual daily closing readings. Daily consumption summaries are retained for 400 days. Normal samples are at least five minutes apart; window changes may add samples earlier. Updates keep this storage in place. |
| Unreadable-history recovery | At most one private recovery copy per account, at most 2 MiB, before replacing an unreadable cache. Kept locally for troubleshooting and removed with the account. |
| Notification deduplication state | Private alert state; no chats or credentials |
| Browser profile choice and custom CLI location | Private preferences; remembered CLI metadata includes path, size, modification time, and inode |
| API reporting and balance keys | Non-synchronizing, device-only macOS Keychain items |
| Subscription credentials | Provider-managed authentication; new app-owned Codex profiles require Keychain |
| Provider CLI profiles, caches and logs | Provider-managed directories; additional accounts use separate profiles under the app's Application Support folder |

For new isolated Claude profiles, Ai-llowance detects a plaintext credential fallback after login and before usage reads, logs out and removes the detected fallback. This does **not** guarantee the CLI never temporarily writes credentials. Existing Claude/Codex profiles keep their existing provider credential policy. Ai-llowance does not extract subscription tokens.

Pending Codex authorization links stay in memory until completion, cancellation, or timeout. Copy sign-in link places the current link on your clipboard at your request; it is not saved in account settings.

The retained legacy status-line helper can write a private quota-only feed under `ClaudeFeeds` when explicitly used. New connections do not use it; the normal refresh path removes the old integration when still owned by Ai-llowance. This exception does not store transcripts or credentials.

Chrome profile names are read from its Local State file only to populate the profile picker. Browser cookies, passwords, and session tokens are not read. Notifications are opt-in, local, and may display account nicknames and allowance state on your lock screen according to macOS settings. Launch at Login is also opt-in.

The app is not sandboxed: it needs to launch installed provider CLIs. Select only executables you trust. macOS Keychain and private file permissions do not protect against every program already running with your user privileges.

## Screenshots and reports

Ordinary screenshots can reveal email addresses, nicknames and usage. Hiding names in the menu bar saves space; accessibility labels and the dropdown can still identify accounts. It is not a privacy mode.

Use the documented `--export-preview` command for share images. It creates fictional accounts before reading settings and cannot export live account data. The README screenshots use reserved example email addresses and invented readings.

The optional **Settings → Advanced → Review diagnostics** report is generated locally only when requested. It includes numeric app, macOS and detected CLI versions, provider types, connection/error categories, reading age, reset availability and history counts. It excludes account names, emails, IDs, usage amounts, credential values, file paths, raw errors and raw provider output. Review the report before explicitly copying it; the app does not submit it. Version probes use only `--version`, with bounded output and a deadline.

Connection probes print success metadata, not emails, credentials or quota amounts. Do not include account files, profile directories, raw provider output or unredacted screenshots in public bug reports. Security reports belong in [private vulnerability reporting](https://github.com/jamesatFRM/Ai-llowance/security/advisories/new).

## Disconnecting and deleting

Removing a connection removes its app-owned reading/history cache and alert state. Removing an API connection also deletes its saved key. Removing an app-owned Codex connection signs it out; an existing shared Codex profile is preserved. For Claude, use **Accounts → More → Sign out in Terminal** before removing the connection if you want to end its provider-managed sign-in. Signing out a shared profile affects other tools using it.

Pause stops polling; Quit stops the app. Removing the app bundle alone does not erase settings, provider profiles, Keychain entries or provider-side records. Sign out and remove accounts first; you may then delete the app's Application Support folder. Provider-side data must be managed with the provider. There is no maintainer-held account database to delete.

## Release checks

Source and reachable Git history are checked for common secret patterns, private files, real email addresses and machine paths. Release archives have an exact file allowlist and separate checks. These checks reduce accidental disclosure; they are not a guarantee that no vulnerability exists. Automated 0.3.0 downloads are ad-hoc signed, unnotarized previews. Developer ID/notarization tooling is available for separately configured releases; its presence is not evidence that a download is notarized.

## Application updates

Sparkle checks the signed GitHub release feed about once per day when enabled, or when you select Check for Updates. These HTTPS requests expose ordinary network metadata such as IP address and installed application version to GitHub; account settings, quota readings, provider credentials and chats are not attached. System profiling is disabled. Updates are cryptographically verified and install only when you choose. Automatic checks can be turned off in Settings. Sparkle preferences use this app's macOS user-defaults domain. Update signing keys are separate from provider sign-ins.
