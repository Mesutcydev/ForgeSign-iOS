# AGENTS.md

## Cursor Cloud specific instructions

ForgeSign is a **macOS/Xcode-only iOS app** (SwiftUI + an Obj-C++ bridge into the vendored
zsign/OpenSSL signing engine). It **cannot be built, run, or tested inside the Linux Cloud
Agent VM.** Do not spend time trying to make `xcodebuild`/tests pass here — they physically
cannot: Apple's frameworks (`SwiftUI`, `UIKit`, `Security`), the iOS SDK, the iOS Simulator,
and Xcode itself are macOS-only. `swiftc -typecheck App/ForgeSignMobileApp.swift` on Linux
fails with `no such module 'SwiftUI'`.

### Where the app is actually built/tested
- Real build/test happens only on macOS with **Xcode 26+** (needs the iOS 26 SDK; deployment
  target iOS 16) plus **XcodeGen** — see `README.md` "Build from source" and the CI workflow
  `.github/workflows/ios.yml` (runs on `macos-26`). Do not duplicate those commands here;
  read those files.
- Schemes: `ForgeSignMobileTests` (Swift `Testing`, runs on the iOS Simulator, builds the
  `ForgeSignUISim` target) and `ForgeSignMobile` (device Release build). `xcodegen generate`
  regenerates `ForgeSignMobile.xcodeproj` from `project.yml`.

### What CAN be done on Linux (manifest validation only)
The only useful check available in this VM is validating `project.yml` by generating the
Xcode project with XcodeGen built for Linux. This is optional and not part of startup:

1. Install the Swift toolchain for Linux (Swift 6.x, ubuntu24.04 tarball from
   `download.swift.org`) and put `usr/bin` on `PATH`.
2. Build XcodeGen from source: `git clone --branch 2.43.0 https://github.com/yonaskolb/XcodeGen`
   then `swift build -c release`.
3. Generate: from the repo root run `LOGNAME=$(id -un) USER=$(id -un) xcodegen generate`.
   - Gotcha: XcodeGen aborts with `Couldn't find current username` unless `LOGNAME` is set.
   - The generated `.xcodeproj` is gitignored (`*.xcodeproj/`).

### Dependencies / layout gotchas
- No SwiftPM/npm/pip dependencies. OpenSSL and zsign are **vendored** under `vendor/`, so there
  is nothing to `install` on startup for this repo.
- The vendored OpenSSL ships **device slices only (no simulator slice)**. That is why a separate
  `ForgeSignUISim` simulator target exists: it compiles just the SwiftUI/App layer and excludes
  the zsign bridge (no `FORGE_BRIDGE`, no bridging header, no OpenSSL link flags). Signing is
  stubbed in the simulator via `SigningService`.
- `docs/` is a static marketing site (`docs/index.html` + images), not the application.
