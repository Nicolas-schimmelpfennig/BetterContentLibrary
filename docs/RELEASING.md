# Releasing the macOS app

Updates ship through [Sparkle](https://sparkle-project.org): the app checks an
appcast feed hosted on this repo's rolling **`updates`** GitHub release, and
installs new versions in-app (menu: **BetterContentLibrary → Check for
Updates…**, plus scheduled background checks the user opts into on second
launch).

## Cutting a release

```sh
scripts/release-macos.sh 0.2-alpha
```

That archives a Release build with the version baked in, exports it signed
with Developer ID, notarizes and staples it (so Gatekeeper opens it cleanly
on any Mac), zips it, signs it with the EdDSA key, regenerates
`appcast.xml`, and uploads both to the `updates` release. Users get the
update within Sparkle's next check (or immediately via Check for Updates…).

Finally it **removes the build leftovers** it just created — the
`build/export-*` directory and the `build/*.xcarchive` — keeping only the
version-tagged `updates/*.zip` (the shipped bytes) and, moved aside first,
the `build/dSYMs/<version>/` symbols. This matters: every stray exported
`.app` (and the copy nested inside each xcarchive) registers itself with
LaunchServices, so Spotlight and "Open With" keep surfacing old versions as
though they were still installed — the machine looks like updates never
remove anything. After a release, the only installed copy is the one in
`/Applications`, which Sparkle replaces in place on each update.

The argument is the *marketing* version — any human-readable string
("0.2-alpha", "1.0"). Update ordering doesn't depend on it: Sparkle compares
`CFBundleVersion`, which the script derives from the clock
(`YYYYMMDD.HHMM`), so every release automatically outranks all earlier ones.
Both show in Settings' footer: `v0.2-alpha (20260704.1930)`.

If notary credentials aren't stored yet, the script warns and skips
notarization instead of failing — in-app updates still work (Sparkle doesn't
quarantine what it installs); only fresh downloads hit Gatekeeper.

## Requirements on the release machine

- The **EdDSA private key** in the login Keychain (created by Sparkle's
  `generate_keys`; account `ed25519`). Without it, signing fails and no
  update can be published — export a backup via
  `generate_keys -x <file>` and keep it in `~/Secrets/`. The matching public
  key is baked into the app (`SUPublicEDKey` in
  `BetterContentLibrary/Info.plist`); losing the private key means shipping a
  new key + manual reinstall on every machine.
- A **Developer ID Application** certificate in the Keychain (one-time:
  Xcode → Settings → Accounts → your team → Manage Certificates… → **+** →
  Developer ID Application; needs the paid Developer Program and usually the
  Account Holder role).
- **Notary credentials** stored once as the `bcl-notary` keychain profile:

  ```sh
  xcrun notarytool store-credentials bcl-notary \
      --apple-id <your apple id> --team-id 226AMQMFG9
  ```

  When prompted for a password, use an **app-specific password** generated
  at account.apple.com (not your real Apple ID password).
- `gh` authenticated with push access to the repo.
- The `updates/` folder accumulates one zip per version — leave old ones in
  place so `generate_appcast` can keep prior feed entries and emit delta
  updates.

## First install on a new machine

Grab the newest zip from the `updates` release, unzip into `/Applications`,
double-click. Builds are Developer ID-signed and notarized, so Gatekeeper
opens them without complaint; Sparkle handles all updates from there.

(Anyone still running an old pre-notarization build: right-click → Open
once, or just replace it with a fresh download.)

## iOS

Not covered here — iOS can't self-update; distribution there goes through
TestFlight/App Store when set up.
