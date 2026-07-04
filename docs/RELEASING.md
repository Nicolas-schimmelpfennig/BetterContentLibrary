# Releasing the macOS app

Updates ship through [Sparkle](https://sparkle-project.org): the app checks an
appcast feed hosted on this repo's rolling **`updates`** GitHub release, and
installs new versions in-app (menu: **BetterContentLibrary → Check for
Updates…**, plus scheduled background checks the user opts into on second
launch).

## Cutting a release

```sh
scripts/release-macos.sh 1.1
```

That archives a Release build with the version baked in, zips it, signs it
with the EdDSA key, regenerates `appcast.xml`, and uploads both to the
`updates` release. Users get the update within Sparkle's next check (or
immediately via Check for Updates…).

Pick a version higher than the last one (plain `MAJOR.MINOR` or
`MAJOR.MINOR.PATCH`); Sparkle compares `CFBundleVersion`, which the script
sets to the same value.

## Requirements on the release machine

- The **EdDSA private key** in the login Keychain (created by Sparkle's
  `generate_keys`; account `ed25519`). Without it, signing fails and no
  update can be published — export a backup via
  `generate_keys -x <file>` and keep it in `~/Secrets/`. The matching public
  key is baked into the app (`SUPublicEDKey` in
  `BetterContentLibrary/Info.plist`); losing the private key means shipping a
  new key + manual reinstall on every machine.
- `gh` authenticated with push access to the repo.
- The `updates/` folder accumulates one zip per version — leave old ones in
  place so `generate_appcast` can keep prior feed entries and emit delta
  updates.

## First install on a new machine

Grab the newest zip from the `updates` release, unzip into `/Applications`.
Builds are currently signed with an Apple **Development** certificate, not
Developer ID, so Gatekeeper will complain on first launch: right-click →
Open → Open. After that first launch, Sparkle handles all future updates
without any Gatekeeper friction.

Proper fix when it matters: sign with a Developer ID certificate and
notarize (requires the paid Apple Developer Program), then first installs
are frictionless too.

## iOS

Not covered here — iOS can't self-update; distribution there goes through
TestFlight/App Store when set up.
