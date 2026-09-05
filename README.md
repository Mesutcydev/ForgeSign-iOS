# ForgeSign for iOS

On-device IPA re-signer for iPhone and iPad. Sign and prepare IPAs on-device; installation uses a loopback server and a trusted remote HTTPS manifest, with no certificate or app-content upload.

**[Explore the ForgeSign site](https://mesutcydev.github.io/ForgeSign-iOS/)** · **[Download ForgeSign 2.4](https://github.com/Mesutcydev/ForgeSign-iOS/releases/download/v2.4/ForgeSign-2.4.ipa)**

ForgeSign wraps the battle-tested [zsign](https://github.com/zhlynn/zsign) C++ engine (with a static OpenSSL) in a SwiftUI "liquid glass" interface and adds a complete signing workflow on top of it.

<p align="center">
  <img src="docs/screenshot-sign.png" alt="ForgeSign Sign tab — on-device IPA signer" width="280" />
  &nbsp;
  <img src="docs/screenshot-library.png" alt="ForgeSign Library — signed app history" width="280" />
</p>

<p align="center"><sub>Certificate and provisioning identifiers are redacted in the Sign preview.</sub></p>

## Features

- **Sign IPAs on-device** — pick an `.ipa`, a `.p12` certificate and a `.mobileprovision` profile, optionally rewrite the bundle ID, strip app extensions or enable Files sharing, and sign in seconds with the vendored zsign engine.
- **Remembered certificates** — imported `.p12` files are validated once and stored on-device (Application Support). The last-used certificate is re-selected automatically.
- **Certificate insights** — common name, organization and team ID are parsed from the certificate, and a live countdown pill shows remaining validity (`200d left`, amber under 30 days, red when expired).
- **Keychain passwords** — opt-in password storage only in the device-bound iOS Keychain; if Keychain storage is unavailable, ForgeSign asks for the password again.
- **Install on device** — semi-local OTA install: the IPA is served over loopback HTTP while a trusted remote HTTPS plist (`api.palera.in`) drives `itms-services` directly (Safari is a fallback only). The external manifest service receives install metadata and the local package URL.
- **Library** — a persistent history of every signed app with status (signed / installing / delivered / installed / missing), plus reinstall, share and delete actions.
- **IPA preflight** — package, bundle, encryption and architecture signals are shown before a signing run.
- **Per-bundle provisioning audit** — the app and every extension show their resolved bundle ID and matching-profile status before signing; only the profiles needed by that IPA are passed to the signer.
- **Optional Apple Account provisioning** — ForgeSign can create matching profiles for the app, extensions, and File Provider / attachment bundles. It tries this iPhone’s AuthKit anisette first, then AltServer, then an optional anisette HTTP server (needed on macOS 27 when AltServer cannot read `machineID`). Manual imported-profile signing remains available.
- **Sources** — save repository feeds and hand selected IPA downloads into the normal signing flow.
- **Optional dylib injection** — inject a compatible decrypted dylib into the app, with an opt-in app-extension path, before signing. The original IPA is left untouched.
- **Glass design language** — lighter translucent cards, ambient color blooms, Liquid Glass on iOS 26+ with a material fallback back to iOS 16, light and dark themes.

## Requirements

- Xcode 26+ (the build needs the iOS 26 SDK for the Liquid Glass APIs; deployment target is iOS 16)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 16.0+ on device
- Optional: AltServer on the same local network, or an anisette server (`http://YOUR-MAC-IP:6969`) when using Apple Account provisioning on macOS 27

## Build from source

```bash
xcodegen generate
open ForgeSignMobile.xcodeproj
```

Build the `ForgeSignMobile` scheme for a device. Code signing is disabled in the project settings by design — sign the produced app with your own certificate and profile (ForgeSign desktop can do it, or any sideloading tool).

The device target pins the last AltSign Swift Package revision whose Apple Account authentication path remains enabled. Its scheme pre-action repairs a stale OpenSSL folder reference in that upstream package before compilation.

Package a device build with the checked packaging script (the output must not already exist):

```bash
python3 scripts/package_ipa.py pack /path/to/Release-iphoneos/ForgeSign.app ForgeSign.ipa
python3 scripts/package_ipa.py validate ForgeSign.ipa
```

This excludes Finder metadata and AppleDouble resource forks (`._*`, including misleading `Payload/._ForgeSign.app` entries), preserves executable permissions, and validates the single-app Payload. For an existing IPA, use `repack INPUT.ipa OUTPUT.ipa`; all retained app contents are verified byte-for-byte. Packaging validation does not test Apple authentication or prove installation on a device.

## Sideload the prebuilt IPA

Grab `ForgeSign-2.4.ipa` from [ForgeSign 2.4](https://github.com/Mesutcydev/ForgeSign-iOS/releases/tag/v2.4). The IPA ships **unsigned** — that is the point of the app: sign it like any other IPA.

1. Download the IPA.
2. Sign it with your certificate + provisioning profile — e.g. with ForgeSign (desktop or the iOS app itself), Sideloadly, AltStore or a similar tool.
3. Install the signed IPA on your device.

Only sign and install applications you have the rights to modify. Intended for your own builds and development use.

## Apple Account provisioning

Turn on **Use Apple Account with AltServer**, enter the Apple Account credentials and device UDID, and keep at least one anisette source available. When ForgeSign itself is installed by AltStore, its `ALTDeviceID` placeholder is populated automatically. The password is held only for the current run and is sent to Apple by AltSign.

On iOS/macOS 27, AltServer’s built-in anisette often fails with a missing `machineID`. ForgeSign then uses this iPhone, or an anisette server you run locally:

```bash
docker run -d --restart always --name anisette-v3 -p 6969:6969 dadoum/anisette-v3-server
```

Enter `http://YOUR-MAC-LAN-IP:6969` in **Anisette URL**. If AltServer is discovered, ForgeSign also tries port 6969 on that Mac automatically.

If Apple Account provisioning cannot finish, signing continues with the imported certificate and profile. Extensions and attachment / File Provider bundles then use the app profile.

ForgeSign reuses a matching imported or previously generated certificate. It deliberately refuses to revoke an unknown existing certificate, because doing so could invalidate AltStore and other installed apps. On a free account already occupied by AltStore, use a separate Apple Account or import the exact matching P12. Normal free-account App ID, active-app and seven-day expiry limits still apply.

## What’s new in 2.4

- Restores signing when an IPA has extensions or attachment bundles but only the app profile is imported.
- Works around the macOS 27 AltServer `machineID` anisette failure by using this iPhone first, then AltServer, then an optional anisette HTTP server.
- Keeps Apple Account provisioning for per-extension and App Group profiles when anisette is available, and falls back to the imported profile when it is not.

## What’s new in 2.3

- Replaces the proposed custom Mac companion with direct discovery and communication with an existing AltServer.
- Adds on-device AltSign authentication, two-factor verification, device registration, safe certificate handling, extension App IDs, shared App Groups and per-bundle profile downloads.
- Preserves manual certificate/profile signing and refuses to revoke an inaccessible AltStore certificate.
- Includes the stable signing header and Home Screen install handoff fixes from 2.2.

## What’s new in 2.2

- Adds a pre-sign profile check for the root app and every extension, with specific bundle ID, team, certificate, device, expiry, and App Group errors.
- Uses only the matching profiles, signs nested bundles before the root app, preserves original identifiers in `ALTBundleID`, and records each resolved profile’s groups in `ALTAppGroups`.
- Adds per-bundle automatic-provisioning hooks; direct AltServer support is completed in 2.3.
- Verifies the final IPA’s signatures, embedded profiles, resolved application identifiers, and `ALTAppGroups` metadata before saving it.
- Keeps the ForgeSign header stable while signing and returns to the Home Screen after handing the install request to iOS.

## What’s new in 2.1

- IPA previews in the iOS Files app now show ForgeSign in the bottom quick-action menu.
- Tapping ForgeSign opens the app with the selected IPA already loaded into the signing workflow.
- IPA registration now uses Apple’s canonical file type while ordinary ZIP archives remain a separate alternate import path.

## What was new in 2.0

- Restores v1.1 behavior: extension-bearing IPAs are no longer rejected by the preflight gate before signing.
- The visible Remove app extensions option remains available, while nested profile matching and final signing validation still fail safely when inputs are incompatible.
- Includes the v1.9 wildcard app-identity fix and certificate/profile picker state fixes.

## What was new in 1.9

- Fixes the Files picker that opened but let you select nothing on sideloaded builds by expanding wildcard application identifiers to concrete bundle IDs.
- Fixes certificate and provisioning-profile picker state across nested sheet dismissal.

## What was new in 1.7

- Uses explicit `UIDocumentPickerMode.import` so sideloaded builds request a local copy instead of opening documents in place.

## What was new in 1.6

- Fixed disabled picker items by using the concrete `public.data` import type instead of abstract `public.item`.
- Declared IPA, dylib, certificate, and provisioning-profile filename UTIs in `Info.plist` for Files provider compatibility.

## What was new in 1.5

- Fixed Files picker selection for sideloaded builds by using an unfiltered import-mode picker instead of dynamic extension UTIs.
- IPA, dylib, certificate, and provisioning-profile extensions are validated after selection, then copied into the app container for reliable processing.

## What was new in 1.4

- Fail-closed IPA extraction with archive limits, structural validation, and mandatory post-sign verification.
- Certificate/profile/team/bundle-ID compatibility gates and CMS-verified provisioning profiles.
- Reliable install delivery accounting, exact HTTP ranges, cancellation, Library state parity, and honest `delivered` status.
- Files/Open In routing, HTTPS repository policy, atomic protected persistence, and Keychain-only password storage.
- 1.3 wildcard iCloud entitlement and Files-picker fix retained.

## What was new in 1.3

- Wildcard and placeholder iCloud entitlements are removed before signing so Files document pickers continue working in installed apps.
- Valid iCloud container entitlements are preserved, while the existing document-browser workaround remains in place.
- 1.2 install reliability, staging cleanup, and Sources feed fixes are included.

## What was new in 1.2

- Install server honours HTTP Range requests, so flaky installs resume instead of restarting.
- Silent-audio keep-alive stops as soon as you return without a download, not only after delivery.
- Staged archives are pruned to the current pick and the signing temp folder is wiped on relaunch.
- Sources feeds use stable row identity (refreshes no longer detach in-flight downloads).
- Wildcard-profile iCloud entitlement stripping extended to kvstore/container-environment leftovers.

## What was new in 1.1

- Preflight card for package, bundle, encryption and architecture checks.
- Optional dylib injection with app-extension support for compatible decrypted Mach-O inputs.
- Sources tab with repository feeds and direct IPA handoff.
- Lighter glass surfaces and refreshed dark-mode screens.

![ForgeSign Sign tab in dark mode](docs/screens/screenshot-sign-dark.png)

![ForgeSign Sources and Library tabs in dark mode](docs/screens/screenshot-sources-dark.png) ![ForgeSign Library tab in dark mode](docs/screens/screenshot-library-dark.png)

## How it works

1. Picked files are staged into the app container.
2. The zsign engine (`Bridge/`) re-signs the Mach-O binaries, injects the profile and rewrites metadata, producing `<name>-signed.ipa` in the persistent Signed library.
3. Install serves the IPA on `http://127.0.0.1:<port>`, obtains a trusted HTTPS `manifest.plist` from `api.palera.in` that points at that IPA, then opens `itms-services://` directly so iOS prompts to install.

## Project layout

```
App/            SwiftUI UI (glass design system in App/Design), stores and services
Bridge/         Obj-C++ bridge into the zsign engine
vendor/zsign    Vendored zsign signing engine
vendor/openssl  Static OpenSSL (libcrypto/libssl) for the engine
project.yml     XcodeGen manifest (regenerates the .xcodeproj)
```

## Third-party

- [zsign](https://github.com/zhlynn/zsign) — signing engine (vendored)
- [OpenSSL](https://www.openssl.org) — static cryptography libraries (vendored)
- [AltSign](https://github.com/rileytestut/AltSign) — Apple-account and provisioning API integration (Swift Package, pinned revision)
