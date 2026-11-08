# ForgeSign 2.8.1 release audit — 8 November 2026

Pre-publication check of the 2.8.1 artifacts, metadata and site. The attached
IPA was built from `e705408`; this document is the only change made after it,
and it touches no app source.

**Verdict: clean. Nothing blocked publication.**

## Build and repository

- `release/2.8` and `main` both at `e705408`; working tree clean.
- Required checks passed on `e705408` for both branches: dependency bootstrap
  against `scripts/dependencies/lock.json`, `git diff --check`, packaging tests,
  native signing/resource/crypto scripts, and the simulator test suite.
- Locally before the commit: 79 simulator tests, 10 packaging and dependency
  tests, and the three native scripts all passed.
- App source changed since the 2.8 build (`7eb3453`) is only the readable-width
  fix in `ContentView`, `SourcesView`, `LibraryView` and `DesignTokens`, plus the
  version bump. A semantic plist comparison confirms `Info.plist` differs from
  2.8 in `CFBundleShortVersionString` and `CFBundleVersion` alone; the remaining
  textual diff is `plutil` reordering two keys.

## Package

- `ForgeSign-2.8.1.ipa`, 4,489,319 bytes, 11 entries, the same layout as the 2.8
  package. Single `Payload/ForgeSign.app` root.
- No `__MACOSX`, `._*` or `.DS_Store` entries, and nothing outside `Payload/`.
- No `.dSYM` or `.bcsymbolmap` debug artifacts.
- `ForgeSign`, `AltSign-Dynamic` and `OpenSSL` are mode `0755` and arm64 only;
  no simulator slice is shipped.
- Bundle identifier `com.forgesign.mobile`, version `2.8.1 (32)`, minimum OS
  16.0, device family `[1, 2]`, and all four iPad orientations declared.
- No `embedded.mobileprovision` and no `_CodeSignature`: the package is unsigned,
  exactly as the notes state.
- Against the 2.8 package the only differences are the app binary (+73,968
  bytes) and `Info.plist` (+2 bytes). Both frameworks, `Assets.car` and the
  icons are byte-identical.

## Release assets

- `ForgeSign-2.8.1.ipa` and `ForgeSign-latest.ipa` are byte-identical.
- Every entry in `SHA256SUMS.txt` recomputes correctly.
- `ThirdPartyNotices.txt` is identical to `App/Resources/ThirdPartyNotices.txt`.
- `Whats-New-2.8.1.txt` is identical to `WHATS_NEW.md`, and the release body
  matches it too.
- The audit link in the notes resolves.

## Site

- `mesutcydev.github.io/ForgeSign-iOS` is built from `e705408` and shows 2.8.1.
- The three download links and the release-notes link are present and point at
  `releases/latest`, so they follow the published release.

## Known gaps carried forward

- Apple Account login/2FA and certificate reuse are unverified.
- Signing an extension-bearing IPA on a registered device is unverified. Profile
  parsing and per-bundle matching were checked against real Apple-issued app and
  share-extension profiles; the signing half needs the matching private key.
- Installation of this exact build on a physical device was not retried; 2.8 was
  verified that way and the delta is a SwiftUI layout modifier.
