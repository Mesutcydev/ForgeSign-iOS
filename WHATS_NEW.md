# ForgeSign 2.8.2

A follow-up to 2.8.1 that restores Apple Account sign-in with community anisette servers and lands fixes from a full code audit. Everything in the 2.8 and 2.8.1 notes still applies.

## What's new

- **Apple Account sign-in with community anisette servers.** Since mid-October 2026 Apple's GrandSlam rejects sign-ins whose client identity doesn't match the anisette server that generated the data (-80045, or an HTML 503). ForgeSign now signs in with the User-Agent and client info the server reports in `/v3/client_info`, and requests SMS codes through Apple's current JSON endpoints (the plist form now fails with HTTP 415). Ported from AltSign's `notarized` branch onto the pinned revision.
- **Refresh installs as an upgrade.** A Library refresh re-signs the kept original with the installed app's bundle ID and original file name, so it replaces the installed app instead of adding a second one.
- **Provisioning no longer leaks a bundle ID.** A bundle ID filled in by Apple Account provisioning is cleared when you pick a different IPA, so the next app can't be signed with the previous app's identity.
- **Packaging.** Apps whose name contains "Payload" (for example `PayloadKit.app`) are packaged with a correct `Payload/` root again, after signing and after dylib injection.
- **Install server.** A file read error during an OTA transfer is reported instead of crashing the app, and a Range header the server can't use is ignored (full download) rather than refused. Returning to ForgeSign mid-download no longer silences the keep-alive, and a server that finished starting after a cancel is stopped.
- **Everyday use.** The chosen certificate is remembered across launches, Keychain password lookups are no longer repeated on every redraw, deleting a certificate or profile asks first, 2FA codes can be filled from Messages, section titles are VoiceOver headings, and the AltServer row stops showing "Searching…" forever.

## Validation

CI on this build: dependency bootstrap from checksum-pinned sources (including the updated AltSign patch over the pinned revision), native signing invariants, simulator tests, the device Release build, and IPA packaging/validation.

Apple Account sign-in and 2FA (trusted device and SMS), refresh-as-upgrade, and OTA installation on a registered device remain to be verified on hardware.

## Download

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.2.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.2 (33)**. SHA-256 checksums are attached to this release.
