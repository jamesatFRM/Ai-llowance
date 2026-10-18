# Installer and update releases

Default builds and CI artifacts are ad-hoc signed, unnotarized previews. Developer ID signing and notarization are also supported locally, with Apple credentials kept on the maintainer's Mac. A local signing certificate alone does not make a build notarized; successful submission, stapling, and assessment are required before publication. Sparkle Ed25519 signatures provide update authenticity independently of Apple signing.

## Normal updates

Push reviewed changes to main. The required `macos` check validates privacy, tests, universal binaries, packaged contents, signatures, the Applications shortcut, and Finder layout. A separate publish job, gated by `SIGNED_RELEASES_ENABLED=true`, runs only after success on main, signs the DMG and feed, publishes an immutable versioned preview, then advances the `update-feed` asset. Pull requests do not receive signing secrets. The workflow does not require Actions to create PRs or bypass branch protections.

**Keep `SIGNED_RELEASES_ENABLED=false` during the transition to a notarized release and after a stable release occupies the shared feed.** This pauses preview publication, not CI validation. Re-enabling the existing preview job would allow a later unnotarized build to replace that feed. Stable releases can instead be built, notarized, and signed locally without uploading Apple credentials to GitHub. Keep preview publication paused unless it gets a separate feed or CI gains a required notarization gate.

The app checks the stable GitHub feed daily when enabled. Users can check manually and choose Install and Relaunch. Update installation runs through Sparkle and existing account storage/bundle identity remain unchanged. Version 0.1.0 had no updater and needs a one-time DMG installation. Install in Applications, then eject the image before using updates.

Every workflow run uses a monotonically increasing build number (200 + workflow run number). A named release changes `VERSION`; plain source pushes can produce updates under the same display version. Rerunning a published build refuses to replace differing archives. Publication is serialized by the workflow's concurrency group; new main runs do not cancel an active publish and the feed changes only after release assets exist.

## Signing keys

The dedicated `Ai-llowance` Sparkle key lives in the maintainer's login Keychain. Only its public key is committed at `Resources/update-public-key.txt`. The maintainer previously approved the dedicated key's encrypted `SPARKLE_PRIVATE_KEY` Actions secret; the preview publishing gate controls whether CI uses it. That approval applies only to the Sparkle update key. Apple signing certificates, private keys, and notary credentials can remain exclusively in the local Keychain. Back up the Keychain securely: losing the Sparkle key prevents updates to existing ad-hoc installations. Never commit, print, or attach private keys to a release.

For a local signed release, run `bash scripts/package-release.sh` followed by `bash scripts/sign-release.sh vVERSION-buildNUMBER`. This uses the dedicated Keychain key. The tools and Sparkle runtime are pinned and verified; the signed feed must not be edited after signing.

## Local Developer ID and notarization path

The scripts support Developer ID signing and notarization on the maintainer's Mac. **This documentation does not certify that any particular release has completed notarization.** Verify the submission and packaged artifacts before publishing. Membership in the Apple Developer Program alone does not provide the certificate/private key or authenticated notary profile on the Mac.

Prerequisites are an installed Developer ID Application certificate **with its private key**, compatible Xcode tools including `notarytool` and `stapler`, and a notarytool credential profile stored in the local Keychain. Configure the profile interactively with `xcrun notarytool store-credentials Ai-llowance-notary`; do not paste credentials into chat, source files, or release logs. No Apple signing credentials are uploaded by these scripts.

Run the existing package script with these non-secret configuration values:

```sh
USAGEBAR_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
USAGEBAR_NOTARY_PROFILE='Ai-llowance-notary' \
USAGEBAR_REQUIRE_NOTARIZATION=1 \
USAGEBAR_ARCHITECTURES='arm64 x86_64' \
bash scripts/package-release.sh
```

The pipeline signs Sparkle's nested helpers and XPC services, the framework, UsageBridge, and the app in dependency order. Distribution signatures use hardened runtime and secure timestamps. Sparkle's Downloader retains its upstream entitlements. Signing uses explicit targets, never `codesign --deep`; deep verification remains enabled.

It then submits a temporary app ZIP using the Keychain profile, requires an `Accepted` result, staples and validates the app, and only then creates the release ZIP and DMG. The DMG is signed, separately submitted, stapled, and validated before checksums or Sparkle signatures are generated. Gatekeeper assessment must pass for both the packaged app and DMG. A missing identity/profile/tool, rejection, invalid ticket, or failed assessment stops the command. The preview path remains available when notarization is not requested.

The bundle's `AILPreviewBuild` metadata controls its version label. Default builds, including Developer ID builds without a notarization request, keep the preview label. A build with required notarization configuration uses a plain version label; the package pipeline must still finish all notarization checks before that artifact is distributed. Old or missing metadata defaults to preview. The app performs no runtime signing or notarization probes for this label.

Before changing production publication, verify clean-Mac drag/install/launch, privacy permissions and provider sign-in, automatic launch, and an actual Sparkle update from an existing preview while preserving accounts. Test both Intel and Apple silicon. Local release publication does not require Apple credentials in CI. Moving notarized publication into CI later would require a separate credential setup and a production release gate; these are **not configured** by this change. Keep the existing Sparkle public key and bundle identity during that transition, and use a new build number higher than every published build.

Official references: [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), and [Sparkle's explicit signing order](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## Release completion and artwork

An update is complete when the notarized, signed release is live in the shared Sparkle feed and an existing installed copy can discover, install, and relaunch it. A source push or merge alone does not deliver an app update. Report production status explicitly.

Every public release must include a promotional image showing the exact version/build and verified new features or fixes. Match the established deep navy, cyan/violet, glass-card Ai-llowance identity and white A monogram. Review text and provider logos (Codex uses OpenAI branding, never xAI). Use illustrative UI only as an illustration, never as screenshot proof. Save the image and generation prompt durably, attach the image to the versioned GitHub release, and share it with the user.
