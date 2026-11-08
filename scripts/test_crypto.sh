#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
frameworks="$PWD/vendor/openssl/OpenSSL.xcframework/macos-$(uname -m)"
certificate_dir="$PWD/vendor/AltSign/AltSign/Model/Apple API"
test -f "$frameworks/OpenSSL.framework/OpenSSL"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-sign-compare \
    -mmacosx-version-min=15.0 -I "$certificate_dir" \
    -I "$frameworks/OpenSSL.framework/Headers" -F "$frameworks" \
    "$certificate_dir/ALTCertificate.m" scripts/tests/forgesign_crypto_test.m \
    -framework Foundation -framework OpenSSL -Wl,-rpath,"$frameworks" \
    -o "$test_dir/crypto-test"
"$test_dir/crypto-test"
