# Provider expansion boundaries

Checked against official documentation and source on 2026-10-16. Implemented parsers and synthetic protocol tests do not establish that an actual account can use these integrations. No new provider credentials or authenticated accounts were used for this work.

## GitHub Copilot

The adapter starts an installed CLI only for a bounded quota read: `--headless --no-auto-update --stdio --log-level none`. It uses the official SDK's Content-Length JSON-RPC framing, `connect` handshake (legacy method-not-found fallback to `ping`), protocol version 3, `auth.getStatus`, and `account.getQuota`. The CLI exits after the read. No session, prompt, inference, tool, or conversation operation is sent.

Account identity is read before and after the quota request and checked against the connection's saved binding. Only existing user or GitHub CLI authentication is accepted; inherited API keys are removed. The app does not read token files or call credential-returning APIs. Selecting additional saved Copilot identities is not enabled: the older account-list RPC can return tokens, and a credential-free selected-identity flow needs separate verification. Sign in through the official Copilot CLI first. Organization accounts also need the organization to enable Copilot CLI.

Quota buckets remain separate. Unlimited entitlements are represented explicitly, never as a fake 100%-remaining finite allowance. Missing or malformed quota is unavailable. Paid overage permission does not inflate an included allowance. The API is experimental and version-gated; live acceptance remains outstanding.

Sources: [quota API](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing), [authentication](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate), [official client](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts), [generated schema](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts), [protocol version](https://github.com/github/copilot-sdk/blob/main/nodejs/src/sdkProtocolVersion.ts).

## OpenRouter

One authenticated `GET https://openrouter.ai/api/v1/key` reads the configured key limit and effective budget. The app uses the lowest remaining amount reported for those budgets, preserving separate quota windows. It never calculates a global account balance from key usage. A null key limit with no effective budget means no configured key budget; it does not mean unlimited credits. Reset timestamps are used only when actually supplied. `usage` is not presented as monthly spend. Keys remain in the macOS Keychain.

Source: [current key API](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key). The separate account credits endpoint requires different management-key authorization and is not used.

## Vercel AI Gateway

One authenticated `GET https://ai-gateway.vercel.sh/v1/credits` reads `balance` in USD for the team selected by the key. `total_used` is lifetime spending, so it is not presented as monthly cost or an allowance denominator. The response does not verify a human-readable team name. This is API credit, not a Vercel subscription quota.

Source: [credit balance API](https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance).

## xAI (beta)

One authenticated `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance` uses a Management API key and an explicit team ID. These keys are separate from inference API keys. The response's `total.val` is a signed integer string in USD cents. The app computes prepaid credit as `-Decimal(total.val) / 100`, preserving a negative result rather than turning debt into available funds.

This sign convention is an inference from the official paired examples: a top-up request of 500 cents creates a PURCHASE ledger entry of -500 cents; the balance example reports a successful -1000-cent purchase and total -1000. The app never sends a top-up or other mutation. Unit/sign fixture tests use those examples. Actual-account acceptance remains pending: compare the first displayed amount with the xAI Console before relying on it. No Grok consumer allowance, postpaid spend, or postpaid cap is inferred.

The request restricts and encodes the team path identifier. Reported change entries for another team are rejected. The saved identity is the selected team ID; a changed binding fails before reading a credential.

Sources: [Management key and host](https://docs.x.ai/developers/management-api-guide), [billing schema and paired examples](https://docs.x.ai/developers/rest-api-reference/management/billing), [team ID settings](https://docs.x.ai/developers/rest-api-reference/management/auth).

## Not enabled

- **Cursor individual:** Official CLI release notes document `/usage` with plan meters and reset. A zero-inference headless quota export was not verified; print mode must not be presumed safe for this command. Team Admin API spending is distinct from individual plan quota. [CLI changelog](https://cursor.com/docs/cli/changelog), [Admin API](https://cursor.com/docs/account/teams/admin-api).
- **Gemini CLI / Code Assist:** `/stats model` documents interactive quota, but headless JSON statistics concern session tokens and latency. The internal `retrieveUserQuota` implementation is not a supported third-party API contract. No scraping, copied OAuth credentials, or inference requests were added. [Quotas](https://geminicli.com/docs/resources/quota-and-pricing/), [headless reference](https://geminicli.com/docs/cli/headless/).

All HTTP reads use the existing ephemeral, bounded, no-redirect transport. No browser process, SDK runtime, local server, or new dependency is bundled for these integrations.
