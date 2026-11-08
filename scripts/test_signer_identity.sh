#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
c++ -std=c++11 -Wall -Wextra -Werror -I vendor/zsign \
    scripts/tests/forgesign_identity_test.cpp -o "$test_dir/forgesign_identity_test"
"$test_dir/forgesign_identity_test"
# The vendored plist code is not -Werror clean; only the test itself is strict.
Z=vendor/zsign/common
for f in json base64 log util fs; do
    c++ -std=c++11 -w -I vendor/zsign -I "$Z" -c "$Z/$f.cpp" -o "$test_dir/$f.o"
done
c++ -std=c++11 -Wall -Wextra -Werror -I vendor/zsign -I "$Z" \
    scripts/tests/forgesign_entitlements_test.cpp "$test_dir"/*.o -o "$test_dir/forgesign_entitlements_test"
"$test_dir/forgesign_entitlements_test"
