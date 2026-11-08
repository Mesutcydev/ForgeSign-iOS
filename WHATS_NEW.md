# ForgeSign 2.8.1

A small follow-up to 2.8. Everything in the 2.8 notes still applies; this build adds the iPad layout fix found during the follow-up QA pass.

## What's new

- **Readable iPad layout.** Sign, Sources and Library now keep their content at a readable width instead of stretching every row across the display. On a 13-inch iPad in landscape each label and its control sat about a thousand points apart; they now stay together in a centred column. iPhone layouts are below the cap and are unchanged.
- **Steadier dependency bootstrap.** Checksum-pinned source downloads retry a temporary network failure before giving up, and still refuse any archive whose checksum does not match.

## Validation

79 simulator tests passed. iPad QA covered Sign, Sources and Library in portrait and landscape, in light and dark appearances, and at the largest accessibility text size. ForgeSign's provisioning parser and matcher were additionally exercised against real Apple-issued profiles for an app and its share extension: each nested bundle resolved to its own profile, and an app profile alone correctly left the extension blocked rather than being reused for it.

Apple Account/2FA, certificate reuse and signing an extension-bearing IPA on a registered device remain unverified. See [the full audit](https://github.com/Mesutcydev/ForgeSign-iOS/blob/main/AUDIT_2026-11-08.md) for details.

## Download

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.1.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.1 (32)**. SHA-256 checksums and a plain-text copy of these notes are attached to this release.
