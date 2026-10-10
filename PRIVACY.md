# Privacy

Ai-llowance runs locally on your Mac. There is no Ai-llowance backend, analytics service, advertising, cloud sync, or automatic updater. The maintainer does not receive your account identities, usage, credentials, or diagnostic logs from the app.

## What leaves your Mac

Subscription checks use the installed Claude Code and Codex CLIs, which contact their providers. Optional API spending checks send your reporting key directly to the provider's fixed HTTPS reporting endpoint. Login and dashboard links open provider pages in your browser. These services have their own privacy and retention policies.

Ai-llowance requests no model responses or conversation history. Claude's local `/usage` command may itself inspect local activity to prepare its report; Ai-llowance keeps only recognized plan limits and rejects reports with model turns or model cost. This is a version-dependent CLI integration.

For processes it starts, Ai-llowance sets Claude's `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`, and Codex's `analytics.enabled=false` and `feedback.enabled=false`. These process-scoped settings do not change your other CLI sessions or stop necessary authentication and quota traffic. Provider implementations and managed policies remain outside this app's control. See the official [Claude data-use documentation](https://code.claude.com/docs/en/data-usage) and [Codex configuration reference](https://developers.openai.com/codex/config-reference/).

## What stays on your Mac

| Data | Storage |
|---|---|
| Account nicknames, connection choices, preferences | Private files under `~/Library/Application Support/UsageBar` |
| Expected Codex email | Saved privately with connection settings to detect account changes |
| Current signed-in email and quota readings | Normal app state in memory; visible in the interface |
| Organization reporting API keys | Non-synchronizing, device-only macOS Keychain items |
| Subscription credentials | Provider-managed authentication; new app-owned Codex profiles require Keychain |
| Provider CLI profiles, caches and logs | Provider-managed directories; additional accounts use separate profiles under the app's Application Support folder |

For new isolated Claude profiles, Ai-llowance detects a plaintext credential fallback after login and before usage reads, logs out and removes the detected fallback. This does **not** guarantee the CLI never temporarily writes credentials. Existing Claude/Codex profiles keep their existing provider credential policy. Ai-llowance does not extract subscription tokens.

Pending Codex authorization links stay in memory until completion, cancellation, or timeout. Copy sign-in link places the current link on your clipboard at your request; it is not saved in account settings.

The retained legacy status-line helper can write a private quota-only feed under `ClaudeFeeds` when explicitly used. New connections do not use it; the normal refresh path removes the old integration when still owned by Ai-llowance. This exception does not store transcripts or credentials.

The app is not sandboxed: it needs to launch installed provider CLIs. Select only executables you trust. macOS Keychain and private file permissions do not protect against every program already running with your user privileges.

## Screenshots and reports

Ordinary screenshots can reveal email addresses, nicknames and usage. Hiding names in the menu bar saves space; hover and accessibility labels still identify accounts. It is not a privacy mode.

Use the documented `--export-preview` command for share images. It creates fictional accounts before reading settings and cannot export live account data. The README screenshots use reserved example email addresses and invented readings.

Connection probes print success metadata, not emails, credentials or quota amounts. Do not include account files, profile directories, raw provider output or unredacted screenshots in public bug reports. Security reports belong in [private vulnerability reporting](https://github.com/jamesatFRM/Ai-llowance/security/advisories/new).

## Disconnecting and deleting

Removing an API connection deletes its saved key. Removing an app-owned Codex connection signs it out; an existing shared Codex profile is preserved. For Claude, use **Accounts → More → Sign out in Terminal** before removing the connection if you want to end its provider-managed sign-in. Signing out a shared profile affects other tools using it.

Pause stops polling; Quit stops the app. Removing the app bundle alone does not erase settings, provider profiles, Keychain entries or provider-side records. Sign out and remove accounts first; you may then delete the app's Application Support folder. Provider-side data must be managed with the provider. There is no maintainer-held account database to delete.

## Release checks

Source and reachable Git history are checked for common secret patterns, private files, real email addresses and machine paths. Release archives have an exact file allowlist and separate checks. These checks reduce accidental disclosure; they are not a guarantee that no vulnerability exists. The 0.1.0 download is an ad-hoc signed, unnotarized preview.
