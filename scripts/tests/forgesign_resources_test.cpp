#include "common/sha.h"
#include "common/fs.h"
#include <cassert>
#include <iostream>

int main(int argc, char** argv)
{
    assert(argc == 2);
    const std::string directory = argv[1];
    const std::string emptyFile = directory + "/empty";
    const std::string contentFile = directory + "/content";
    const std::string missingFile = directory + "/missing";
    assert(ZFile::WriteFile(emptyFile.c_str(), ""));
    assert(ZFile::WriteFile(contentFile.c_str(), "abc"));

    std::string sha1, sha256;
    assert(ZSHA::SHAFile(emptyFile.c_str(), sha1, sha256));
    assert(sha1.size() == 20 && sha256.size() == 32);
    std::string emptySHA1, emptySHA256;
    assert(ZSHA::SHA("", emptySHA1, emptySHA256));
    assert(sha1 == emptySHA1 && sha256 == emptySHA256);
    assert(ZSHA::SHABase64File(contentFile.c_str(), sha1, sha256));
    assert(sha1 == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=");
    assert(sha256 == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");

    // A failed mapping must not become the digest of an empty resource.
    assert(!ZSHA::SHAFile(missingFile.c_str(), sha1, sha256));
    assert(sha1.empty() && sha256.empty());
    sha1 = sha256 = "stale digest";
    assert(!ZSHA::SHABase64File(missingFile.c_str(), sha1, sha256));
    assert(sha1.empty() && sha256.empty());
    assert(!ZSHA::SHAFile(directory.c_str(), sha1, sha256));

    std::string data;
    assert(!ZFile::ReadFile(directory.c_str(), data));
    assert(!ZFile::ReadFile(missingFile.c_str(), data));
    assert(ZFile::ReadFile(emptyFile.c_str(), data) && data.empty());
    assert(ZFile::ReadFile(contentFile.c_str(), data) && data == "abc");
    std::cout << "Resource hashing and file-read regressions passed.\n";
}
