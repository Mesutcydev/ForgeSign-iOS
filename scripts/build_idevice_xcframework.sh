#!/usr/bin/env bash
#
# Builds vendor/idevice/IDevice.xcframework from a PINNED idevice revision.
#
# This is a maintainer/build-machine script, never a CI step: it needs Rust,
# Xcode's SDKs, and several minutes of compilation. The produced framework is
# deterministic for a given revision + feature set + Rust toolchain, and its
# SHA-256 is written next to it so the artifact stays accountable.
#
#   ./scripts/build_idevice_xcframework.sh
#
# After it succeeds, run `xcodegen generate` and the Direct Device transport
# compiles in (the Swift wrapper is guarded by `#if canImport(IDevice)`).
#
# License: idevice is MIT (https://github.com/jkcoxson/idevice).
# We build only the FFI static library; no upstream code is modified.

set -euo pipefail

IDEVICE_REPO="https://github.com/jkcoxson/idevice.git"
IDEVICE_REV="${IDEVICE_REV:-v0.1.68}"
# Minimal feature set for ForgeSign: reach the device over the tunnel (tcp),
# inspect/install packages (afc, installation_proxy, misagent), pair, and do
# RSD/core-device work later. rustcrypto keeps the build free of aws-lc/ring C
# toolchains so it stays reproducible on any Mac.
IDEVICE_FEATURES="${IDEVICE_FEATURES:-tcp,usbmuxd,afc,installation_proxy,misagent,pair,rsd,core_device_proxy,heartbeat,rustcrypto,remote_pairing,tunnel_tcp_stack}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${IDEVICE_WORK_DIR:-$REPO_ROOT/build/idevice-src}"
OUT_DIR="$REPO_ROOT/vendor/idevice"
FRAMEWORK="$OUT_DIR/IDevice.xcframework"

log() { printf '\033[1m[idevice]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[idevice] error:\033[0m %s\n' "$1" >&2; exit 1; }

command -v cargo >/dev/null || fail "cargo not found. Install Rust (brew install rustup && rustup default stable)."
command -v rustup >/dev/null || fail "rustup not found. Install it with 'brew install rustup' and run 'rustup default stable'."
command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode."

log "toolchain: $(rustc --version 2>/dev/null || echo 'unknown')"

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  if ! rustup target list --installed | grep -qx "$target"; then
    log "adding rust target $target"
    rustup target add "$target"
  fi
done

if [ ! -d "$WORK_DIR/.git" ]; then
  log "cloning idevice $IDEVICE_REV"
  mkdir -p "$(dirname "$WORK_DIR")"
  git clone --depth 1 --branch "$IDEVICE_REV" "$IDEVICE_REPO" "$WORK_DIR"
else
  log "reusing $WORK_DIR"
fi

cd "$WORK_DIR"
log "checked out $(git rev-parse --short HEAD) ($(git describe --tags --always))"

build_target() {
  local target="$1" sdk="$2"
  log "building $target (sdk: $sdk)"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --target "$target" --no-default-features --features "$IDEVICE_FEATURES" \
    --manifest-path "$WORK_DIR/ffi/Cargo.toml"
}

build_target aarch64-apple-ios iphoneos
build_target aarch64-apple-ios-sim iphonesimulator

DEVICE_LIB="$WORK_DIR/target/aarch64-apple-ios/release/libidevice_ffi.a"
SIM_LIB="$WORK_DIR/target/aarch64-apple-ios-sim/release/libidevice_ffi.a"
HEADER="$WORK_DIR/ffi/idevice.h"
[ -f "$DEVICE_LIB" ] || fail "missing $DEVICE_LIB"
[ -f "$SIM_LIB" ] || fail "missing $SIM_LIB"
[ -f "$HEADER" ] || fail "missing generated header $HEADER (cbindgen step failed)"

# Rust release archives keep symbol tables for backtraces; stripping is what
# takes each slice from ~80 MB to ~19 MB without losing functionality.
log "stripping debug symbols"
strip -x "$DEVICE_LIB" "$SIM_LIB"

log "staging headers + framework"
rm -rf "$FRAMEWORK" "$OUT_DIR/include"
mkdir -p "$OUT_DIR/include"
cp "$HEADER" "$OUT_DIR/include/idevice.h"
cat > "$OUT_DIR/include/module.modulemap" <<'MODULEMAP'
module IDevice {
  header "idevice.h"
  export *
}
MODULEMAP

xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$OUT_DIR/include" \
  -library "$SIM_LIB" -headers "$OUT_DIR/include" \
  -output "$FRAMEWORK" >/dev/null

REVISION="$(git -C "$WORK_DIR" rev-parse HEAD)"
cp "$HEADER" "$OUT_DIR/idevice.h"
cat > "$OUT_DIR/README.md" <<EOF
# Vendored idevice FFI (generated)

Produced by \`scripts/build_idevice_xcframework.sh\`. Do not edit by hand.

- upstream: $IDEVICE_REPO (MIT)
- revision: $IDEVICE_REV (\`$REVISION\`)
- features: \`$IDEVICE_FEATURES\`
- targets: aarch64-apple-ios, aarch64-apple-ios-sim
- rustc: $(rustc --version 2>/dev/null | head -1)

Rebuild with the script; it rewrites this file and the checksum.
EOF

(
  cd "$OUT_DIR"
  find . -type f ! -name 'CHECKSUMS.txt' -print0 | sort -z | xargs -0 shasum -a 256 > CHECKSUMS.txt
)
log "checksums written to vendor/idevice/CHECKSUMS.txt"
shasum -a 256 "$OUT_DIR/idevice.h" | awk '{print "  header sha256: "$1}'
du -sh "$FRAMEWORK" | awk '{print "  xcframework: "$1}'
log "done — run 'xcodegen generate' to link it"
