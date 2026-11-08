#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
openssl_root="${FORGESIGN_TEST_OPENSSL_ROOT:-}"
if [ -z "$openssl_root" ]; then
    openssl_root="$(brew --prefix openssl@3)"
fi
test -f "$openssl_root/include/openssl/sha.h"
Z=vendor/zsign/common
for f in json base64 log util fs sha; do
    c++ -std=c++11 -w -I vendor/zsign -I "$Z" -I "$openssl_root/include" \
        -c "$Z/$f.cpp" -o "$test_dir/$f.o"
done
c++ -std=c++11 -Wall -Wextra -Werror -I vendor/zsign -I "$Z" \
    scripts/tests/forgesign_resources_test.cpp "$test_dir"/*.o \
    -L "$openssl_root/lib" -lcrypto -o "$test_dir/forgesign_resources_test"
"$test_dir/forgesign_resources_test" "$test_dir"
