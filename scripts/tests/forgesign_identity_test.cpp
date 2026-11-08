#include "forgesign_identity.h"
#include <cassert>

int main()
{
    assert(FSConcreteApplicationIdentifier("TEAM.*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    assert(FSConcreteApplicationIdentifier("TEAM.com.example.*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    assert(FSConcreteApplicationIdentifier("TEAM.com.example.*", "com.example.app.share", "TEAM") ==
           "TEAM.com.example.app.share");
    assert(FSConcreteApplicationIdentifier("*", "com.example.app", "TEAM") ==
           "TEAM.com.example.app");
    assert(FSConcreteApplicationIdentifier("*", "com.example.app", "") == "*");
    assert(FSConcreteApplicationIdentifier("TEAM.com.example.app", "com.other.app", "TEAM") ==
           "TEAM.com.example.app");
    assert(FSConcreteApplicationIdentifier("TEAM.com.example.*", "", "TEAM") ==
           "TEAM.com.example.*");
}
