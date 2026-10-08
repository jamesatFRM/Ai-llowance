# Security

Ai-llowance is a preview. It is not independently security-audited, Developer ID signed, or notarized.

Do not post credentials, raw authentication responses, or private account details in issues. Use GitHub's private vulnerability reporting in this repository's Security tab for security reports. If that option is unavailable, open an issue asking for a private reporting channel without disclosing the vulnerability or any sensitive data.

## Data and credentials

- Writes create private temporary files before writing and atomically replace their destination. Saved settings are size-bounded and validated; invalid files are preserved instead of silently reset.
- Share-image export loads only fictional in-memory accounts, without reading or replacing saved account settings.
- Account labels and connection settings are local, under `~/Library/Application Support/UsageBar`, with private file permissions. Quota snapshots and email labels stay in process memory.
- Organization API keys are stored in this Mac's non-synchronizing Keychain. Background reads do not prompt repeatedly if Keychain is locked.
- Codex and Claude manage their own subscription credentials. App-owned Codex profiles require Keychain. New isolated Claude login launchers reject Claude's plaintext fallback. Existing CLI profiles keep their existing credential policy.
- Ai-llowance invokes locally installed provider CLIs. Their version, behavior, authentication, and network traffic remain controlled by the provider. The app does not bundle them or inspect their token files.
- API requests use fixed HTTPS origins, GET-only reporting endpoints, bounded responses, and no redirects, shared cookies, or URL cache.
- There is no Ai-llowance analytics service, telemetry endpoint, cloud sync, or automatic updater.

## Removal

Remove API connections in Accounts to delete their saved keys. Removing an app-owned Codex account signs it out; existing Codex sign-ins are preserved. For Claude, use Accounts → More → Sign out in Terminal before removing an account if you want to clear that provider-managed sign-in. Signing out an existing CLI profile also affects other tools using that profile.

Quit Ai-llowance before replacing or deleting the app. Removing the app bundle alone does not delete provider-managed sign-ins or local account settings.
