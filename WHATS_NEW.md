# ForgeSign 2.8

## What's new

- **Reliable OTA installation.** Fixes a local connection race that could stop installation before the iOS prompt. Partial IPA downloads work correctly, and Cancel stops remaining transfer data.
- **Visible download progress.** Repository downloads show byte progress and support cancellation. A 2 GiB streaming limit protects storage, and repository icons use bounded HTTPS downloads.
- **Responsive, safer imports.** Large IPA and dylib copies run in the background with progress and cancellation. Failed or cancelled imports preserve the previous input. Certificate and profile pickers return reliably to the signing workflow.
- **Better signing checks.** Preflight blocks encrypted or invalid packages, checks certificate expiry, and uses the matching profiles selected for the app and its nested bundles.
- **Library recovery and storage controls.** Retry or cancel installation from Library, recover interrupted attempts after restarting, and clear signed copies, downloads, kept originals or the current input separately.
- **Clear Liquid Glass and accessibility.** Keeps the clear glass appearance across cards and controls, with native switches, labeled fields, Dynamic Type and layouts that accommodate long names.
- **Compatibility fixes.** Fixes clean launches with the iOS 27 SDK and an expiry-check crash on earlier iOS 27.2 beta builds.
- **Updated signing engine dependencies.** Upgrades both signing engines to one shared OpenSSL 3.5.9 LTS framework, with modern and legacy P12 support and checksum-pinned source builds.

## Validation

79 simulator tests, native signing and crypto checks, and IPA packaging checks passed. Manual signing, independent signature verification, OTA installation and launching the signed sample were verified on a registered iPhone.

Apple Account/2FA, real matching extension profiles and wider iPad visual QA are not covered by this hardware validation. See [the full audit](https://github.com/Mesutcydev/ForgeSign-iOS/blob/main/AUDIT_2026-11-08.md) for details.

## Download

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8 (31)**. SHA-256 checksums and a plain-text copy of these notes are attached to this release.
