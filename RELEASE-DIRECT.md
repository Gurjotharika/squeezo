# Releasing the website edition

The website edition is the `CompressDirect` target: same code as the App Store app, built with the `DIRECT` flag.
It unlocks with a Dodo Payments license key and updates itself through Sparkle.

Source lives in the private repo `Gurjotharika/squeezo`. Only finished builds go to the public repo
`Gurjotharika/squeezo-releases`: the DMG, and `appcast.xml`, which the app reads to find updates.

## One-time setup
1. **Developer ID certificate.** Xcode → Settings → Accounts → your team → Manage Certificates → `+` → *Developer ID Application*.
   Xcode can also manage it in the cloud, which is what the export step uses; it won't show in `security find-identity`.
2. **Notarization login.** Create an app-specific password at appleid.apple.com, then run once:
   `xcrun notarytool store-credentials squeezo-notary --apple-id <your Apple ID> --team-id U253D92J7M`
3. **Sparkle signing key.** Already in your login keychain (`.tools/sparkle/bin/generate_keys` showed it). The matching public key is
   `SUPublicEDKey` in `project.yml`. Back it up: `.tools/sparkle/bin/generate_keys -x squeezo-sparkle-private.key`, and keep that
   file somewhere safe and out of git. Lose it and existing installs can never be updated.
4. **Dodo Payments.** The product's License Key entitlement sets how many Macs one key can activate. The app uses only Dodo's public
   endpoints (`/licenses/activate`, `/validate`, `/deactivate`), so no API key is in the app. Never put one there.
   Set `DodoEnvironment` to `test` in `project.yml` to try test-mode keys.

## Every release
`Scripts/release-direct.sh 1.0.1 2` (version, then a build number higher than the last one). It archives, signs with Developer ID,
notarizes and staples the app, puts it in a DMG, signs the update for Sparkle, writes `appcast.xml`, and creates the GitHub release.
Add `--no-publish` to build everything in `build/direct/<version>` without uploading.

Link your website's download button to
`https://github.com/Gurjotharika/squeezo-releases/releases/latest/download/Squeezo.dmg`.

## How customers' apps update
The app checks `https://github.com/Gurjotharika/squeezo-releases/releases/latest/download/appcast.xml` daily (and from
*Check for Updates…*). A newer `sparkle:version` than the installed build offers an update, which Sparkle downloads, verifies
against the public key, installs and relaunches.

## How licensing behaves
- Enter key → activated against this Mac → stored in the Keychain.
- Re-checked every 24 hours. Offline Macs keep working for 14 days since the last good check.
- Refunded or revoked keys lock the app at the next check. *Deactivate on This Mac* in Settings frees the activation.
