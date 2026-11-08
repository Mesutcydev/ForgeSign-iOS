#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir="${1:-$PWD/build/bridge-probe}"
mkdir -p "$probe_dir"
probe_dir="$(cd "$probe_dir" && pwd)"
frameworks="$PWD/vendor/openssl/OpenSSL.xcframework/macos-$(uname -m)"
includes=(-I Bridge -I vendor/zsign -I vendor/zsign/common -I "$frameworks/OpenSSL.framework/Headers")
objects=()
for source in vendor/zsign/*.cpp vendor/zsign/common/*.cpp Bridge/zsign_wrapper.cpp; do
    [[ "$source" == vendor/zsign/zsign.cpp ]] && continue
    object="$probe_dir/${source//\//_}.o"
    xcrun clang++ -std=c++11 -w -mmacosx-version-min=15.0 "${includes[@]}" -c "$source" -o "$object"
    objects+=("$object")
done
for source in ioapi zip unzip; do
    object="$probe_dir/minizip-$source.o"
    xcrun clang -w -mmacosx-version-min=15.0 -c "vendor/zsign/third-party/minizip/$source.c" -o "$object"
    objects+=("$object")
done
xcrun clang++ -std=c++11 -mmacosx-version-min=15.0 "${includes[@]}" \
    scripts/tests/forgesign_bridge_probe.cpp "${objects[@]}" -F "$frameworks" \
    -framework OpenSSL -framework CoreFoundation -lz -Wl,-rpath,"$frameworks" \
    -o "$probe_dir/bridge-probe"
echo "$probe_dir/bridge-probe"
