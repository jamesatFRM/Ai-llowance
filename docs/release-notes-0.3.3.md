# Ai-llowance 0.3.3

- Attention shortcuts and account notifications reveal the selected account in Settings, even when another tab was open or the same account was selected before.
- Setup help for managed Codex accounts uses the same Keychain credential store as usage monitoring. Claude/Codex help launchers clear inherited API/cloud-routing overrides so subscription setup stays on the intended path.
- First-account setup transitions to the connected account without leaving a stale welcome panel. Advanced connections have a direct View account action.
- Setup and error messages stay visible beneath the Settings tabs and can be dismissed.
- Minimized or hidden Settings no longer keep the faster visible-window refresh cadence. Opening Settings restores a minimized window.

The compact interface, branding, and saved account preferences are preserved. No extra polling loop, timer, or runtime dependency was added.
