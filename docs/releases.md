# Installer and update releases

Ai-llowance 0.2.0 is a preview. No Apple Developer ID certificate is configured, so downloads are ad-hoc signed and unnotarized. The DMG improves installation; it does not remove macOS's first-launch approval requirement. Sparkle Ed25519 signatures provide update authenticity independently of Apple signing.

## Normal updates

Push reviewed changes to main. The required `macos` check validates privacy, tests, universal binaries, packaged contents, signatures, the Applications shortcut, and Finder layout. A separate publish job, gated by `SIGNED_RELEASES_ENABLED=true`, runs only after success on main, signs the DMG and feed, publishes an immutable versioned preview, then advances the `update-feed` asset. Pull requests do not receive signing secrets. The workflow does not require Actions to create PRs or bypass branch protections.

The app checks the stable GitHub feed daily when enabled. Users can check manually and choose Install and Relaunch. Update installation runs through Sparkle and existing account storage/bundle identity remain unchanged. Version 0.1.0 had no updater and needs a one-time DMG installation. Install in Applications, then eject the image before using updates.

Every workflow run uses a monotonically increasing build number (200 + workflow run number). A named release changes `VERSION`; plain source pushes can produce updates under the same display version. Rerunning a published build refuses to replace differing archives. Publication is serialized by the workflow's concurrency group; new main runs do not cancel an active publish and the feed changes only after release assets exist.

## Signing keys

The dedicated `Ai-llowance` Sparkle key lives in the maintainer's login Keychain. Only its public key is committed at `Resources/update-public-key.txt`. Automated publishing requires explicit approval to store the private key in the repository's encrypted `SPARKLE_PRIVATE_KEY` Actions secret. Until then, keep `SIGNED_RELEASES_ENABLED` unset and publish locally signed releases from the maintainer's Mac. Back up the Keychain securely: losing this key prevents updates to existing ad-hoc installations. Never commit, print, or attach it to a release.

For a local signed release, run `bash scripts/package-release.sh` followed by `bash scripts/sign-release.sh vVERSION-buildNUMBER`. This uses the dedicated Keychain key. The tools and Sparkle runtime are pinned and verified; the signed feed must not be edited after signing.

For production distribution, configure Developer ID signing and notarization, sign all nested code consistently, and staple the notarization ticket. That is not configured in this preview.
