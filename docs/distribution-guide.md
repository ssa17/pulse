# macOS App Distribution — Full Guide

## What we're trying to do

Turn source code into a file you can send to someone, and them double-clicking it
to use it — with **zero setup required on their end**.

This is what "distribution" means for macOS.

---

## The journey from source code to distributed app

```
Your source code
    │
    ▼
build.sh (compile Swift, bundle assets)
    │
    ▼
Pulse.app  (~3.6 MB macOS bundle, mostly the Sparkle framework)
    │
    ▼
codesign — "this was made by me" (your Developer ID certificate)
    │
    ▼
notarytool — Apple says "yes, this is safe" (takes ~3 minutes)
    │
    ▼
Pulse.dmg  (the file you give to other people)
```

### What happens at each step

| Step | What it is | Who's involved |
|---|---|---|
| **Build** | Compile Swift binary + bundle HTML/CSS/assets into a `.app` bundle | You (your machine) |
| **Sign** | Stamp the app with your Developer ID certificate so macOS knows it came from you | You (macOS keychain) |
| **Notarize** | Submit the app to Apple's automated review — they check it for malware | Apple's servers (3 min) |
| **DMG** | Wrap the signed app in a `.dmg` (disk image) — the file people download | You (your machine) |

**Why signing + notarization?** macOS asks users for explicit permission the first
time they open an unsigned app. Notarization removes that warning entirely.

---

## What you need (set up once, works forever)

### 1. Apple Developer Account ($99/year)
You have this. It gives you access to:
- **Certificates** — digital stamps that prove your identity
- **Teams** — your organization identifier (TEAM ID)
- **API Keys** — keys that let scripts talk to Apple's servers

### 2. Certificates (on your machine)
When you sign into Xcode with your Developer Account, Xcode downloads these to
your **login keychain** automatically:

| Certificate | Use |
|---|---|
| Developer ID Application | Sign apps for distribution (outside App Store) |
| Apple Distribution | Submit to App Store |
| Apple Development | Debug apps locally |

Check yours: `security find-identity -v -p codesigning`

Save your Team ID (the 10-char string like `5N87BS9C8P`) — it's the same for
every app you make from this account.

### 3. App Store Connect API Key (for notarization)
This is a `.p8` file that lets your scripts **submit apps to Apple's notarization
service**. It is created in **App Store Connect** (not developer.apple.com):

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. **Users and Access** → **Integrations** → **App Store Connect API**
3. Generate a key, check **Developer ID**, download the `.p8`

> ⚠️ **Do not confuse this with the Keys in developer.apple.com → Certificates,
> Identifiers & Profiles.** Those are *Service Keys* (for Push Notifications,
> Sign in with Apple, etc.) and **cannot** be used with `notarytool`. Only App
> Store Connect API keys work for notarization.

Save the `.p8` to `~/.apple/keys/`, then store it in a keychain profile **once**:

```bash
xcrun notarytool store-credentials "notary-profile" \
  --key ~/.apple/keys/AuthKey_XXXX.p8 \
  --key-id XXXX \
  --issuer <issuer-uuid>
```

> ⚠️ **Do not pass `--team-id` to `store-credentials`** — it is grouped with the
> app-specific-password options and triggers a "Cannot store both…" error. The team
> is implied by the key + issuer.

After this, scripts reference the profile with `--keychain-profile "notary-profile"`
— no secrets in any script, ever.

### 4. Fastlane (installed on your machine)
Fastlane is the tool that orchestrates:
- Finding your certificate (from keychain)
- Signing your app (with codesign)
- Submitting to Apple (with notarytool)
- Creating a DMG (with hdiutil)

One command per app: `fastlane distrib`

---

## The per-app workflow (every future app)

```
1. Write your app (Swift, Node, whatever)
2. Write a build script (compile + bundle)
3. Write a Fastfile (tell Fastlane the app name and build script)
4. Run:  fastlane distrib
   - Finds your Developer ID certificate (by Team ID)
   - Runs your build script
   - Signs the .app bundle
   - Submits to Apple's notarization service (~3 min)
   - Staples the ticket to your app
   - Creates a .dmg with nice layout
5. Distribute the .dmg (GitHub Releases, website, email, etc.)
```

The Fastfile is **generic** — you change 2–3 values per app (name, output dir,
build script path). Everything else (certificate lookup, signing, notarization)
is the same.

> ⚠️ **First-submission hold:** the very first notarization under a brand-new
> Developer ID certificate / team is diverted into Apple's secondary "in-depth
> analysis" queue and can take **hours to 2–3 days** (not the usual ~3 min).
> Once that first submission is `Accepted`, Apple recognizes your team and all
> subsequent submissions clear in 1–3 minutes. Don't resubmit duplicate builds
> while the first is `In Progress` — it just adds queue entries.

---

## Setting up a brand-new app (concrete)

For a new app, you need three things, then one command:

**1. A build script** that produces `dist/<AppName>.app` (like `app/build.sh`).

**2. A `fastlane/Fastfile`** — copy the one from Pulse and change the config block:

```ruby
default_platform(:mac)

PROJECT_DIR  = File.expand_path("..")            # parent of fastlane/ dir
APP_NAME     = "MyApp"                            # ← change
BUILD_SCRIPT = "#{PROJECT_DIR}/app/build.sh"      # ← change
APP_BUNDLE   = "#{PROJECT_DIR}/dist/#{APP_NAME}.app"
BINARY_PATH  = "#{APP_BUNDLE}/Contents/MacOS/MyApp"  # ← change (your binary name)
OUTPUT_DIR   = "#{PROJECT_DIR}/dist"
```

Everything else (signing, notarization, DMG) is identical — it reads your
certificate + the `notary-profile` keychain profile automatically.

**3. Run it:**
```bash
cd /path/to/your/app
fastlane distrib        # → dist/MyApp-<version>.dmg
```

> The Fastfile must live in a `fastlane/` directory (Fastlane's convention).
> Use **absolute paths** — Fastlane changes its working directory.

---

## Versioning

macOS apps carry **two** version numbers in `Info.plist`:

| Key | Example | Meaning |
|---|---|---|
| `CFBundleShortVersionString` | `1.2.0` | The **marketing** version users see ("Version 1.2.0") |
| `CFBundleVersion` | `1.0` | The **build** number — must increase with every release, even patch ones |

**How to release a new version:**
1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `app/Info.plist`
2. Run `fastlane distrib`

The Fastfile reads `CFBundleShortVersionString` from the built app for the release
tag and appcast, but the DMG itself has a **stable name** (`Pulse.dmg`, no version)
so the README's "latest download" link —
`https://github.com/<owner>/<repo>/releases/latest/download/Pulse.dmg` — keeps
working across releases without edits. (The Sparkle update zip stays versioned,
since the appcast needs a unique URL per version.)

> **Rule of thumb:** bump the build number (`CFBundleVersion`) for *every* release
> (1.0 → 1.1 → 1.2 … or 2.0), and the marketing version (`CFBundleShortVersionString`)
> when you want users to notice (1.0 → 1.1 → 2.0). This matters for the update
> mechanism below.

---

## Updates: how installed users get new versions

This is the part most people miss. A DMG is a **one-shot install** — once a user
has installed it, nothing tells them a new version exists. You have three options:

### Option 1 — Manual (no extra code)
You publish `Pulse.dmg` to your website / GitHub Releases. Users who want the
update must **manually** download and reinstall. Simple, but most users never will.

### Option 2 — Sparkle (the standard, recommended) — **Pulse uses this**
[Sparkle](https://sparkle-project.org) is the framework nearly all non-App-Store
macOS apps use for auto-updates. How it works:

```
Your app (with Sparkle)
   │  on launch + every few hours
   ▼
GET <SUFeedURL>/appcast.xml   ← a small XML file you host
   │  lists: version, build, release notes, link to the new .app.zip, EdDSA signature
   ▼
If a newer build exists → prompt the user → download → verify signature → install
   ▼
User clicks "Restart and Update"
```

**How Pulse implements it** (all wired up, see the files):
- `vendor/fetch-sparkle.sh` — downloads the pre-built Sparkle 2.10.1 framework
  (gitignored; `app/build.sh` calls it, so fresh clones rebuild it)
- `app/build.sh` — bundles `Sparkle.framework` + `Updater.app` into the `.app`
- `app/Pulse.swift` — `import Sparkle`, an `SPUStandardUpdaterController`, and a
  **Check for Updates…** menu item
- `app/Info.plist` — `SUPublicEDKey` (EdDSA public key) + `SUFeedURL` (the appcast)
- `secrets/sparkle-ed25519.key` — the EdDSA **private** key backup (gitignored;
  the live key is in your macOS keychain)
- `releases/appcast.xml` — the update feed (committed; served via raw GitHub)

**To release a new version** (the whole flow):
```bash
# 1. Bump the version in app/Info.plist  (CFBundleShortVersionString: 1.0 → 1.1)
# 2. Commit + push your code changes
git add -A && git commit -m 'v1.1: <what changed>' && git push
# 3. Release — this does EVERYTHING else automatically:
fastlane release
```
`fastlane release` builds, signs, notarizes, staples, makes the DMG, makes the
Sparkle update zip, publishes a GitHub Release (DMG + zip), regenerates
`releases/appcast.xml`, and commits + pushes it. Installed users' apps then detect
the new appcast entry and offer the update automatically.

> The only manual step is bumping the version in `Info.plist` — a deliberate
> decision (1.0 → 1.1 → 2.0). Everything after that is one command.

> The EdDSA **private** key lives in your keychain (backed up in `secrets/`).
> Never commit it. If you lose it, you can't sign updates that verify against the
> public key already shipped in older app versions — back it up somewhere safe.

### Option 3 — Mac App Store
Automatic updates, but requires App Store review + a different signing cert
(`Apple Distribution`, not `Developer ID`). A separate distribution path.

---

## Does the app / DMG need internet access?

| Thing | Needs internet? | Why |
|---|---|---|
| **Installing from the DMG** | ❌ No | It's a local disk image |
| **Pulse's core function** | ❌ No | It samples the local system + runs a server on `127.0.0.1` |
| **Auto-updates (Sparkle)** | ✅ Yes | The app must reach your `appcast.xml` + download the update |

So: **the DMG and the app work fully offline.** Internet is only needed for
Sparkle auto-updates — and only for the update check/download, not for the app's job.

> Note: Pulse's `Info.plist` has `NSAllowsLocalNetworking` (for the local server).
> Sparkle's internet access is separate and allowed by default.

---

## What the user of your app experiences

```
1. Downloads Pulse.dmg (from your website, GitHub, email)
2. Double-clicks it
3. Sees a nice window with an icon and an Applications folder
4. Drags Pulse.app to Applications (or double-clicks to run directly)
5. Double-clicks Pulse.app in Applications
6. Opens instantly — no warnings, no "from the internet" dialog
7. Works
```

---

## Summary: what to do next

| Order | Action | One-time or Per-App |
|---|---|---|
| 1 | Sign into Xcode with your Developer Account → Xcode downloads certificates to keychain | One-time |
| 2 | Create an App Store Connect API Key (appstoreconnect.apple.com → Users and Access → Integrations) | One-time |
| 3 | Save .p8 to `~/.apple/keys/` + `xcrun notarytool store-credentials "notary-profile"` | One-time |
| 4 | Install Fastlane (`brew install fastlane`) | One-time |
| 5 | Generate a Sparkle EdDSA key (`vendor/sparkle/bin/generate_keys`) + back it up to `secrets/` | One-time |
| 6 | Create a Fastfile (per app, 3 lines change) | Per-App |
| 7 | Run `fastlane distrib` (DMG) or `fastlane release` (DMG + auto-update + GitHub) | Per-Release |

The end state: `fastlane release` → a signed, notarized, auto-updating app published
to GitHub, with installed users getting updates automatically via Sparkle.
