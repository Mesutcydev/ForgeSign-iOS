# ForgeSign 2.8.9

## What's new in 2.8.9

- **Import signing files from Files.** If ForgeSign was installed through AltServer, the certificate or provisioning profile picker could gray out files even when IPA selection worked. Certificate (`.p12` and `.pfx`) and provisioning profile (`.mobileprovision`) imports now use the same copy-mode picker as IPA imports.

## Download

The IPA is **unsigned**. AltServer can sign it during installation.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.9.ipa` and `ForgeSign-latest.ipa` contain the same build, **2.8.9 (40)**. SHA-256 checksums are attached to the release.

## What's new in 2.8.8

A follow-up to 2.8.7 for Apple Account provisioning when the imported certificate belongs to a team the signed-in Apple Account cannot use.

- **Apple Account provisioning uses your account's own team.** Previously, when the imported certificate's team was not available to the signed-in Apple Account, provisioning stopped with "Team … is not available to this Apple Account". It now provisions in the account's own team and records that switch in the signing log. The imported certificate is reused only if that team actually holds it. If the team already has a development certificate ForgeSign has no key for, the existing conflict message still appears, and ForgeSign does not revoke that certificate.

## Validation

Simulator tests: 93 in 10 suites. The device Release build, IPA packaging and IPA validation ran on this build. Installing the signed app on a registered device still needs hardware verification.

## Download

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.8.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.8 (39)**. SHA-256 checksums are attached to this release.

## ForgeSign 2.8.7

A follow-up to 2.8.6 that makes a failed sign explainable, adds a way past a Watch app that has no profile, and tightens signing and install safety after a full audit. Everything in the 2.8.6 notes still applies.

## What's new in 2.8.7

- **A signing log you can read.** Every sign attempt is recorded on the device: its settings, the signing engine's output and the result, including failures that happen before the engine runs. Open **View Signing Log** under any failure or warning to read, copy, share or clear it. The log is protected on the device and left out of backups.
- **Sign without a Watch app.** When a Watch app with no profile is the only thing blocking a sign, the notice offers **Sign Without Watch App**. The Watch app is removed from the signed IPA and will not be installed. The choice applies to that one attempt.
- **Extensions signed with the app's profile verify.** An extension without a profile of its own is signed with the app's profile, as 2.8.4 described, and the output now passes verification. Extensions with their own profile are unchanged.
- **Stronger checks on signed output.** Every sealed file is checked after signing, and the signed bundle ID must match the one you asked for. A changed file under a sealed bundle is rejected.
- **Safer saved data.** An unreadable history, profile, certificate or refresh index is moved aside instead of being overwritten. Remembered passwords are forgotten when the app leaves the foreground, and the refresh budget counts the files on disk.
- **Privacy in provisioning.** The Apple Account email is kept in the Keychain. Each remote anisette server gets its own provisioning data, and plain HTTP is accepted only for local network addresses. The Apple password is cleared after a successful sign-in.
- **Safer installs.** The IPA and the install page are served only under a random per-install token, and the number of connections is limited. A two-factor prompt cancels itself after five minutes.
- **Clearer messages and controls.** Missing App Groups and Watch apps say what to do, and system errors read in plain words. Results and errors no longer linger after new input. Touch targets are at least 44 pt, and the light-mode status colours meet 4.5:1 contrast.
- **Release integrity.** A published release is never replaced by a different build, and the release notes cover only the version being published.

### Validation for 2.8.7

Simulator tests: 93 in 10 suites, including the signing log, index recovery, Watch app removal, the install token and the anisette changes. The signing fixture generates a certificate, profiles, an app with an extension, a framework and a resource, signs and verifies them, and rejects a tampered output. The Python packaging and dependency tests and the shell signer tests pass. The device Release build and IPA validation ran on this build.

Not yet verified on a device: installing a signed app, Apple Account sign-in with two-factor authentication, and the new interface on screen.

### Download for 2.8.7

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.7.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.7 (38)**. SHA-256 checksums are attached to this release.

## ForgeSign 2.8.6

A follow-up to 2.8.5 for apps whose profile does not grant the App Groups they declare. Everything in the 2.8.5 notes still applies.

## What's new in 2.8.6

- **Clear fix when an App Group blocks signing.** If the profile you picked does not grant an App Group the app declares, Sign IPA now names those groups, says to turn them off to sign, and offers **Sign Without App Groups**. The signed app loses access to its shared group data, so features that use that data will not work. Import a profile that grants the groups to keep them. The choice covers one sign attempt; the next attempt asks again.

### Validation for 2.8.6

Simulator tests: 86 in 8 suites, including a new case for signing without App Groups. The device Release build, IPA packaging and IPA validation ran on this build. Installing the signed app on a registered device still needs hardware verification.

### Download for 2.8.6

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.6.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.6 (37)**. SHA-256 checksums are attached to this release.

## What's new in 2.8.5

- **Signing with your imported profile works again.** Since 2.4 an IPA whose bundle ID no imported profile covers was blocked with "No imported provisioning profile matches this bundle ID", even when you picked the profile yourself. 2.8.3 restored that only for a bundle ID you had changed by hand, so an unchanged app still dead-ended — the case a signing-service profile with its own App ID hits. The selected profile now signs the main app whatever the bundle ID is, exactly as it did up to 2.1, and the App row shows **selected profile** as a warning. Authenticity, team, expiry, device and App Group checks still stop signing when they fail. App extensions keep using the app's profile; a Watch app or App Clip is a separate installable product and still needs its own matching profile. iOS can refuse to install an app whose bundle ID its profile doesn't cover, so a wildcard profile or Apple Account provisioning remains the clean path.
- **Apple Account sign-in no longer fails with HTTP 503.** Apple's GrandSlam answers an HTML 503 to any request whose client info names an Xcode client while the anisette data was generated by `akd` — every source ForgeSign uses returns `akd` data. ForgeSign used to synthesize an Xcode identity (`com.apple.dt.Xcode/25183.54.10`) whenever a source did not report one: the AltServer `:6969` fallback, AltServer data with an older Mac build, and the last-resort "this iPhone" path all did. The payload now keeps the source's model and OS and normalizes the client component to `com.apple.akd/1.0`, so the identity always matches the data that accompanies it.
- **The fallback is honest about the Apple error.** A refused sign-in still reports Apple's own status instead of a bare "HTTP 503", and the chosen anisette source stays visible in the Provisioning section.

### Validation for 2.8.5

Simulator tests: 85 in 8 suites, including new cases for the unchanged-bundle-ID fallback and for never sending an Xcode client identity. The device Release build, IPA packaging and IPA validation ran on this build.

The 503 diagnosis was verified against Apple's live GrandSlam endpoint from the host with real anisette data: an Xcode client info returns an HTML 503, the same data with the normalized `akd` identity returns a normal plist response arranged the same way. Apple Account sign-in with a real account and 2FA, and installing a signed app on a registered device, still need hardware verification.

### Download for 2.8.5

The IPA is **unsigned**. Sign it with your own certificate and matching provisioning profile before installing.

[Download the latest IPA](https://github.com/Mesutcydev/ForgeSign-iOS/releases/latest/download/ForgeSign-latest.ipa)

`ForgeSign-2.8.5.ipa` and `ForgeSign-latest.ipa` contain the same build: **2.8.5 (36)**. SHA-256 checksums are attached to this release.

## What's new in 2.8.4

- **Apps with extensions sign again.** An explicit App ID profile covers `TEAM.com.example.app`, never `com.example.app.Share`, so since 2.6 every IPA carrying a share extension, widget or keyboard stopped with "No imported provisioning profile matches this bundle ID" on the extension row. The app's profile now signs those extensions too, with that profile's entitlements, so the embedded profile and the signed entitlements still agree. The extension row shows **selected profile** as a warning naming the profile used. iOS can refuse to install an app whose extension carries a profile that doesn't cover it, so a wildcard profile or Apple Account provisioning is still the clean path, and **Remove app extensions** still signs the app alone. A Watch app or App Clip is a separate installable product and still needs its own matching profile.
- **No more waiting for a 2FA code that was never sent.** When Apple refused to push a verification code to your trusted devices, the refusal was ignored and ForgeSign asked for the code anyway, so sign-in sat waiting for a code that would never arrive. The refusal is now reported with Apple's HTTP status. 2.8.2 added this check to the SMS path; the trusted-device path was missed.

## What's new in 2.8.3

- **Custom bundle IDs sign again.** Since 2.8, setting a new bundle ID that no imported profile covers stopped signing with "No imported provisioning profile matches this bundle ID." The selected profile now signs the main app again, as it did up to 2.7, and the App row shows **selected profile** as a warning. Certificate, team, expiry, device and App Group checks still apply. Extensions still need their own matching profile. iOS can refuse to install an app whose bundle ID its profile doesn't cover, so use a wildcard profile or Apple Account provisioning for a matching one. With Apple Account provisioning ready, ForgeSign asks Apple for a matching profile instead.

## Also included from 2.8.2

- **Apple Account sign-in with community anisette servers.** Since mid-October 2026 Apple's GrandSlam rejects sign-ins whose client identity doesn't match the anisette server that generated the data (-80045, or an HTML 503). ForgeSign now signs in with the User-Agent and client info the server reports in `/v3/client_info`, and requests SMS codes through Apple's current JSON endpoints (the plist form now fails with HTTP 415). Ported from AltSign's `notarized` branch onto the pinned revision.
- **Refresh installs as an upgrade.** A Library refresh re-signs the kept original with the installed app's bundle ID and original file name, so it replaces the installed app instead of adding a second one.
- **Provisioning no longer leaks a bundle ID.** A bundle ID filled in by Apple Account provisioning is cleared when you pick a different IPA, so the next app can't be signed with the previous app's identity.
- **Packaging.** Apps whose name contains "Payload" (for example `PayloadKit.app`) are packaged with a correct `Payload/` root again, after signing and after dylib injection.
- **Install server.** A file read error during an OTA transfer is reported instead of crashing the app, and a Range header the server can't use is ignored (full download) rather than refused. Returning to ForgeSign mid-download no longer silences the keep-alive, and a server that finished starting after a cancel is stopped.
- **Everyday use.** The chosen certificate is remembered across launches, Keychain password lookups are no longer repeated on every redraw, deleting a certificate or profile asks first, 2FA codes can be filled from Messages, section titles are VoiceOver headings, and the AltServer row stops showing "Searching…" forever.
