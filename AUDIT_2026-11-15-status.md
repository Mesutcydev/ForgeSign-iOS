# ForgeSign audit 2026-11-15: status after fixes

Each finding from [AUDIT_2026-11-15.md](AUDIT_2026-11-15.md), with where it stands now.
Verification after the last change: device build, 93 simulator tests in 10 suites, Python
tests, shell signer tests, bridge probe build, and the signing fixture (3 tests, sign and
verify on a generated certificate, profiles, an extension, a framework and a resource).

Legend: **Fixed** = changed and covered by a test or fixture, or verified by build.
**Partial** = improved, with the remainder stated. **Decision** = left as it was on purpose.
**Device check** = changed, but only a real device or CI run can confirm it.

## Signing core and bridge

| ID | Status | What changed | Still open |
|---|---|---|---|
| S1 | Fixed | The verifier accepts the app's profile for an extension whose ID is a dotted child of the app's ID. Covered by the fixture. | — |
| S2 | Partial | Every file in the seal is re-hashed (`files` and `files2`), and the signed bundle ID must match the request. A changed file is rejected by the fixture. | The main executable's code directory is not recomputed. The signer certificate is checked when the profile is validated, not on the output. |
| S3 | Partial | The message now says "failed structure validation: its signature does not verify" instead of "authenticity". | Chain validation to Apple's roots is not implemented. It needs a real profile to test against. |
| S4 | Fixed | An unreadable index (history, profiles, certificates, refresh manifest) is moved aside, never overwritten. Tested. The budget counts files on disk and removes old untracked copies. | — |
| S5 | Fixed | An archive entry must produce exactly its declared size. Plist reads are capped at 16 MB. | No test with a crafted archive. |
| S6 | Fixed | Long plist strings are no longer cut at 1024 bytes. Version and bundle-ID buffers are checked. | — |
| S7 | Fixed | A missing device identifier or certificate list is a named warning, not a silent pass. Tested. | — |
| S8 | Fixed | Remembered passwords are dropped when the app leaves the foreground. A password is replaced in place, not deleted first. Temporary copies are swept at launch. | — |
| S9 | Fixed | Entitlements are not written to the log. The log file has complete file protection and is excluded from backup. | — |
| S10 | Fixed | Validation output is captured in the same attempt, so a certificate or profile mismatch shows its reason. | — |
| S11 | Fixed | The signing worker refuses a profile that is no longer authentic at sign time. | — |

## Network, install and Apple account

| ID | Status | What changed | Still open |
|---|---|---|---|
| N1 | Partial | The code comment and the manifest message say the check does not bind the install. | Binding would need iOS to fetch the checked copy. Not possible with `itms-services`. |
| N2 | Partial | The provisioning blob is stored per server. The disclosure now says remote servers receive the device identifier. | Automatic mode is still the default. Making it opt-in would break sign-in for users who rely on it. **Decision.** |
| N3 | Fixed | Plain HTTP is accepted only for this device, `.local` names, and private or link-local addresses. Everything else must be HTTPS. | Plain HTTP on the local network is still allowed, because the README's custom-server example uses it. **Decision.** |
| N4 | Fixed | Anisette responses are read with a 1 MB cap, and the resource timeout is 60 s. | — |
| N5 | Fixed | A download is capped at the declared size during transfer, and free space is checked (64 MB headroom) before writing. | — |
| N6 | Fixed | With several AltServers on the network the user chooses one. A single one is still selected automatically and shown by name. | Single-server auto-selection stays. **Decision.** |
| N7 | Fixed | The Apple ID is in the Keychain, with a one-time move from preferences. The password is cleared after a successful sign-in. | — |
| N8 | Fixed | Each install uses a random token in the IPA and install-page paths. At most four connections run at once, and headers must arrive within 15 s. Tested. | — |
| N9 | Partial | The code states what the blocklist covers (literal names only). | Resolving hostnames would block LAN catalogs, so the blocklist is not extended. |
| N10 | Fixed | A two-factor prompt cancels after five minutes. An empty code keeps the prompt open with a message (U13). | — |
| N11 | Partial | Manifest mismatch and network failure have separate messages. System errors are shown in plain words. | The catalog is still read fully before its size check, not streamed. |
| N12 | Fixed | A refused Keychain write is reported: the AltServer certificate throws `keychainWriteFailed`, and identity and blob writes are logged. | — |
| N13 | Decision | Not changed. | The Xcode identity claim is needed for Apple sign-in, which works today. Changing it needs a device test with an Apple account. |

## SwiftUI state, accessibility and copy

| ID | Status | What changed | Still open |
|---|---|---|---|
| U1 | Fixed | A new input clears the previous result and error. | — |
| U2 | Fixed | The provisioning warning is cleared on success. | — |
| U3 | Fixed | Removing extensions from the button applies to that attempt only. A manual choice is kept. | — |
| U4 | Fixed | The audit refreshes when the Apple ID, password or anisette URL changes. | — |
| U5 | Fixed | GET has a label, a 44 pt target, and a hint when there is no download link. | — |
| U6 | Fixed | Icon buttons have 44 pt targets. | — |
| U7 | Fixed | The discovery error wraps. | — |
| U8 | Fixed | The repository error shows the HTTP status and has a Try Again button. | — |
| U9 | Fixed | The pill reads "re-sign needed", and the dialog explains why. | — |
| U10 | Fixed | Every sign path that shows a notice writes a log entry. | — |
| U11 | Fixed | The log view uses the app's type scale. | — |
| U12 | Fixed | An import error is shown after the picker has closed. | Needs a device check. |
| U13 | Fixed | An empty code keeps the sign-in waiting, with a message. | — |
| U14 | Fixed | Picker failures are shown. | — |
| U15 | Fixed | The result is shown before the retained copy is made. | — |
| U16 | Fixed | The light status colours are darkened to reach 4.5:1 on white. The dark theme is unchanged. | — |
| U17 | Fixed | Text buttons are at least 44 pt tall. | — |
| U18 | Fixed | The copy named in the audit is updated. | — |
| U19 | Fixed | A failure that retrying cannot fix shows its message, but no Try Again. | — |
| U20 | Fixed | Log reads and writes run on a serial background queue. | — |
| U21 | Not verified | No change. | Whether the Sources list renders eagerly needs Instruments. |

## Build, CI and docs

| ID | Status | What changed | Still open |
|---|---|---|---|
| B1 | Fixed | A release that already exists is never replaced. The same build is a no-op; a different build fails. | Device check: a real tag push. |
| B2 | Fixed | Only a 404 lets the tag check continue. Any other error stops the job. | — |
| B3 | Fixed | The formatting check covers the committed change against `origin/main`. | — |
| B4 | Fixed | CI builds the bridge probe and signs and verifies generated fixtures. | Device check: the first run on the macOS runner. |
| B5 | Fixed | The site shows the current test count (92). | The README's 86 is the 2.8.6 release entry and is kept. |
| B6 | Fixed | The packager rejects debug and preview dylibs, with a test. The CI check no longer hides an unzip failure. | — |
| B7 | Fixed | Release notes are only the current version, and the file must start with that version. The build number must increase. | — |
| B8 | Partial | The release job runs on `ubuntu-24.04`, and a concurrency group is set. | xcodegen and the Xcode version are not pinned, because the Homebrew formula is unversioned. |
| B9 | Fixed | The FAQ names `api.palera.in` and the anisette servers. | — |
| B10 | Fixed | Patch and initializer digests are pinned in `scripts/dependencies/patches.json`. Reuse needs the framework or AltSign tree on disk to match its recorded digest. OpenSSL source is always re-extracted from the verified archive. | Changing the prepare script rebuilds OpenSSL once, because the recipe digest includes the script. |
| B11 | Fixed | The native tests use a checking macro, not `assert`. The resource test links the vendored OpenSSL. | — |
| B12 | Partial | The three stray `ForgeSign-2.4-*.ipa` files are moved to `build/archive-2.4/`, which is ignored. | `SimulatorSlimmer/` is untracked, and the modified files are uncommitted. Committing is your decision. |
