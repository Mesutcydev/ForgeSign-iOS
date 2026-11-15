#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
# The pinned OpenSSL framework that ships in the app (audit B11), not Homebrew's.
framework="$PWD/vendor/openssl/OpenSSL.xcframework/macos-$(uname -m)"
test -f "$framework/OpenSSL.framework/Headers/openssl/sha.h"
Z=vendor/zsign/common
for f in json base64 log util fs sha; do
    c++ -std=c++11 -w -I vendor/zsign -I "$Z" -I "$framework/OpenSSL.framework/Headers" \
        -c "$Z/$f.cpp" -o "$test_dir/$f.o"
done
c++ -std=c++11 -Wall -Wextra -Werror -I vendor/zsign -I "$Z" \
    scripts/tests/forgesign_resources_test.cpp "$test_dir"/*.o \
    -F "$framework" -framework OpenSSL -Wl,-rpath,"$framework" -o "$test_dir/forgesign_resources_test"
"$test_dir/forgesign_resources_test" "$test_dir"
