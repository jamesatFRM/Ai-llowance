# Ai-llowance 0.3.1

A refined native surface keeps the same compact 350px menu, with clearer headings, subtle glass and borders, consistent controls, and the same dense account rows. Light and dark appearance plus Reduce Transparency remain supported.

Reliability fixes for multi-account monitoring and updates:

- A helper closing early now produces a recoverable connection error instead of quitting Ai-llowance.
- Switching CLI accounts during a refresh cannot attach the new quota to the old account. Duplicate cached subscriptions stay unavailable until corrected.
- Reset countdowns account for all equally exhausted limits. Old readings expire promptly and remain visibly marked in expanded details.
- Invalid provider dates, malformed cached histories, and unreasonable retry delays are rejected or bounded.
- Disabling notifications while a permission request is pending stays disabled.
- Release checks verify the downloadable app archives before advancing the signed update feed and reject rollback or changed build contents.

The app retains its native interface, one coalescing timer, and serial provider reads. No runtime dependency was added. Claude checks include one extra local identity check; no prompt or inference is sent.

Claude and Codex support automatic subscription readings. Copilot remains a preview; OpenRouter, Vercel AI Gateway, and xAI report their respective API budgets/credits, not consumer subscription usage. Cursor and Gemini are usage-page shortcuts. Not every optional provider has been verified against a live account.

Distribution status depends on the release: preview CI artifacts are not notarized. A production release is published only after Developer ID signing, Apple acceptance, stapling, Gatekeeper checks, and signed-feed verification.
