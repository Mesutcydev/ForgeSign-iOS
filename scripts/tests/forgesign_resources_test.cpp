// Checks always run. assert() is removed under NDEBUG, which would skip setup
// that these tests depend on (audit B11).
#include <cstdio>
#include <cstdlib>
#define CHECK(expr) do { if (!(expr)) { std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #expr); std::exit(1); } } while (0)

#include "common/sha.h"
#include "common/fs.h"
#include <iostream>

int main(int argc, char** argv)
{
    CHECK(argc == 2);
    const std::string directory = argv[1];
    const std::string emptyFile = directory + "/empty";
    const std::string contentFile = directory + "/content";
    const std::string missingFile = directory + "/missing";
    CHECK(ZFile::WriteFile(emptyFile.c_str(), ""));
    CHECK(ZFile::WriteFile(contentFile.c_str(), "abc"));

    std::string sha1, sha256;
    CHECK(ZSHA::SHAFile(emptyFile.c_str(), sha1, sha256));
    CHECK(sha1.size() == 20 && sha256.size() == 32);
    std::string emptySHA1, emptySHA256;
    CHECK(ZSHA::SHA("", emptySHA1, emptySHA256));
    CHECK(sha1 == emptySHA1 && sha256 == emptySHA256);
    CHECK(ZSHA::SHABase64File(contentFile.c_str(), sha1, sha256));
    CHECK(sha1 == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=");
    CHECK(sha256 == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");

    // A failed mapping must not become the digest of an empty resource.
    CHECK(!ZSHA::SHAFile(missingFile.c_str(), sha1, sha256));
    CHECK(sha1.empty() && sha256.empty());
    sha1 = sha256 = "stale digest";
    CHECK(!ZSHA::SHABase64File(missingFile.c_str(), sha1, sha256));
    CHECK(sha1.empty() && sha256.empty());
    CHECK(!ZSHA::SHAFile(directory.c_str(), sha1, sha256));

    std::string data;
    CHECK(!ZFile::ReadFile(directory.c_str(), data));
    CHECK(!ZFile::ReadFile(missingFile.c_str(), data));
    CHECK(ZFile::ReadFile(emptyFile.c_str(), data) && data.empty());
    CHECK(ZFile::ReadFile(contentFile.c_str(), data) && data == "abc");
    std::cout << "Resource hashing and file-read regressions passed.\n";
}
