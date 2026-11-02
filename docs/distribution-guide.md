# Distribution — signing, notarization, release

Pulse ships as a **signed + notarized DMG** with **Sparkle** auto-updates,
published to GitHub Releases. The whole pipeline is one command; this page
covers what it does and what it needs.

> The detailed one-time setup (Apple Developer account, certificates,
> notarytool profiles, Sparkle key generation) is maintainer-specific and
> lives in `docs/distribution-setup.md` (gitignored — not in the repo).

## The pipeline

| Command | Does |
|---|---|
| `fastlane distrib` | build → sign (Developer ID) → notarize + staple → `dist/Pulse.dmg` |
| `fastlane release` | distrib + Sparkle update zip + GitHub release + appcast (commit + push) |

## What you need (one-time)

- An **Apple Developer account** with a **Developer ID Application**
  certificate in your keychain (`security find-identity -v -p codesigning`)
- A **notarytool** keychain profile named `notary-profile`
  (`xcrun notarytool store-credentials …` — needs an App Store Connect API key)
- **Fastlane** and the **gh** CLI (authenticated)
- The **Sparkle EdDSA private key** in your keychain
  (backup in `secrets/`, gitignored — if you lose it, you can't sign updates
  that verify against the public key already shipped in older versions)

## Releasing

1. Bump the version in `app/Info.plist` and keep `package.json` in sync
   (the build warns if they disagree):
   - `CFBundleShortVersionString` — the marketing version users see
     (bump when users should notice)
   - `CFBundleVersion` — the build number (bump for *every* release; Sparkle
     compares it to detect updates)
2. Commit + push your changes
3. `fastlane release` — does everything else: builds, signs, notarizes,
   staples, makes the DMG + update zip, publishes the GitHub release,
   regenerates `releases/appcast.xml`, commits + pushes it.

Installed apps then detect the new appcast entry and offer the update.

## Where things live

| File | Role |
|---|---|
| `fastlane/Fastfile` | the pipeline (per-app config at the top) |
| `app/build.sh` | builds the `.app` (bundles the Sparkle framework) |
| `vendor/fetch-sparkle.sh` | fetches the pre-built Sparkle framework (gitignored) |
| `releases/appcast.xml` | the Sparkle update feed (committed; served via raw GitHub) |
| `secrets/` | key backups (gitignored — never commit signing keys) |

Notes:

- The DMG has a **stable name** (`Pulse.dmg`, no version) so the README's
  "latest download" link keeps working across releases; the update zip stays
  versioned (the appcast needs a unique URL per version).
- The app and the DMG work fully offline; internet is only needed for Sparkle
  update checks/downloads.
