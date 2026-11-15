// Checks always run. assert() is removed under NDEBUG, which would skip setup
// that these tests depend on (audit B11).
#include <cstdio>
#include <cstdlib>
#define CHECK(expr) do { if (!(expr)) { std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #expr); std::exit(1); } } while (0)

#include "forgesign_identity.h"

int main()
{
    CHECK(FSConcreteApplicationIdentifier("TEAM.*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    CHECK(FSConcreteApplicationIdentifier("TEAM.com.example.*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    CHECK(FSConcreteApplicationIdentifier("TEAM.com.example.*", "com.example.app.share", "TEAM") ==
           "TEAM.com.example.app.share");
    CHECK(FSConcreteApplicationIdentifier("*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    CHECK(FSConcreteApplicationIdentifier("*", "com.example.app", "") == "*");
    CHECK(FSConcreteApplicationIdentifier("TEAM.com.example.app", "com.other.app", "TEAM") ==
           "TEAM.com.example.app");
    CHECK(FSConcreteApplicationIdentifier("TEAM.com.example.*", "", "TEAM") ==
           "TEAM.com.example.*");
}
