# Verified integration boundaries

Checked 2026-10-08 against primary documentation. A documented contract is not evidence that a particular account has access. Authenticated acceptance is reported separately in verification.md.

## OpenAI

The documented local app-server offers `account/read`, `account/rateLimits/read`, and browser login via `account/login/start`. Rate-limit responses can contain several buckets, each with usage percentage, duration, and reset timestamp. UsageBar prefers those buckets over the legacy single bucket. It neither aggregates them into one allowance nor assumes they cover every ChatGPT feature. [App-server documentation](https://developers.openai.com/codex/app-server).

Codex supports ChatGPT sign-in and API-key auth as different modes. Its `keyring` credential store fails instead of falling back to a file. UsageBar forces this mode for its isolated profiles; existing CLI sign-ins remain CLI-managed. [Authentication and credential storage](https://developers.openai.com/codex/auth).

Organization API costs are a separate Admin API operation, `GET /v1/organization/costs`, with pagination and USD values. Ordinary ChatGPT sign-in is not its credential. [Costs reference](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs).

## Anthropic / Claude

**Current implementation:** direct invocation of the installed Claude Code built-in `/usage` command in print mode. Tested on 2.1.294 with safe mode, no tools/MCP, and no session persistence: a successful JSON result contained session, all-model weekly, and Fable weekly plan limits, with `num_turns: 0` and `total_cost_usd: 0`. The packaged Swift adapter reproduced this on the actual subscription. This replaces the earlier passive status-line integration.

The command itself is documented in [Claude's costs guide](https://code.claude.com/docs/en/costs). Its printable plan-row format was verified locally, not claimed as a stable external quota API. Earlier versions may not expose plan percentages in print mode. The parser rejects unknown/incomplete output, model-generated results, and last-known/rate-limited reports; it does not confuse the behavioral usage percentages with quota percentages.

**Earlier integration, retained only for migration:**

Claude Code officially supplies `rate_limits.five_hour` and `rate_limits.seven_day` to a configured status-line command. Fields include used percentage and Unix reset time. The documentation limits availability by plan/version and response state. UsageBar’s helper keeps only these quota fields and a capture timestamp; it does not retain session paths or contents. No account identifier is verified by this feed. Claude Code owns authentication; UsageBar does not reuse its OAuth credentials. [Status-line data and setup](https://code.claude.com/docs/en/statusline).

The organization cost report uses an Admin API key and daily buckets. Amounts are decimal strings in cents, converted to dollars using Decimal. Priority Tier costs are excluded. Reporting can lag; this is API expenditure, not remaining subscription usage. [Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api), [report schema](https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve).

The official CLI also supports `claude auth login --claudeai` and `claude auth status --json`. Distinct `CLAUDE_CONFIG_DIR` directories isolate claude.ai logins and their macOS Keychain entries. This supports automatic current-profile setup and separate new-account launchers. The provider documents a plaintext fallback if Keychain rejects a write; new UsageBar-created profile launchers detect and discard that fallback rather than continuing. [Authentication and multiple accounts](https://code.claude.com/docs/en/authentication), [CLI reference](https://code.claude.com/docs/en/cli-reference).

## Evaluated but excluded from this version

**Google/Gemini:** CLI authentication includes Google login, Gemini API key, and Vertex AI routes. Its `/stats model` command reports session usage and quota information. These documents do not establish a supported external consumer quota API for this app. Google Cloud billing export is a separate project/IAM integration, not a subscription balance exposed by a Gemini inference key. [CLI authentication](https://geminicli.com/docs/get-started/authentication/), [quotas and stats](https://geminicli.com/docs/resources/quota-and-pricing/), [Cloud billing export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery).

**Grok/xAI:** the documented Management API includes API billing and prepaid balance operations; this does not establish access to Grok consumer subscription limits. No consumer quota contract was verified during this research. The API-billing route was not implemented after the scope was narrowed. [Billing Management reference](https://docs.x.ai/developers/rest-api-reference/management/billing).

“Not verified” is intentionally narrower than claiming a provider has no such API. No browser-session scraping or undocumented endpoints were implemented.
