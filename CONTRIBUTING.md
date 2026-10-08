# Contributing

UsageBar is a native macOS app with no third-party runtime dependencies. Keep the menu compact, account setup simple, and provider limits distinct from API spending.

Run `bash scripts/test.sh` and `bash scripts/package-release.sh` before opening a pull request. CI performs the same checks on a fresh macOS runner. `open dist/UsageBar.app --args --preview` shows fictional sample data; quit any running UsageBar instance first.

Provider changes must identify their documented source or explicitly label a version-dependent CLI integration. Do not infer missing quotas, scrape credential files, log authentication payloads, or turn spending into a made-up remaining balance. Include representative synthetic fixtures and rejection cases when changing a parser.

Do not commit real accounts, emails, quota reports, transcripts, keys, local profiles, build caches, or executable downloads. Use `example.com` identities in fixtures. The app deliberately has no analytics or hosted backend.

Small pull requests with a clear user outcome and focused validation are welcome. By contributing, you agree that your contributions are licensed under this repository's MIT License.
