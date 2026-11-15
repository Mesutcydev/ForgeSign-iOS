// Checks always run. assert() is removed under NDEBUG, which would skip setup
// that these tests depend on (audit B11).
#include <cstdio>
#include <cstdlib>
#define CHECK(expr) do { if (!(expr)) { std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #expr); std::exit(1); } } while (0)

#include "forgesign_entitlements.h"

static string plist(const string& body)
{
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>" + body + "</dict></plist>";
}

int main()
{
    const string profile = plist(
        "<key>application-identifier</key><string>TEAM.app.example</string>"
        "<key>com.apple.developer.team-identifier</key><string>TEAM</string>"
        "<key>get-task-allow</key><false/>"
        "<key>com.apple.developer.associated-domains</key><string>*</string>"
        "<key>com.apple.developer.healthkit</key><true/>"
        "<key>keychain-access-groups</key><array><string>TEAM.*</string></array>"
        "<key>com.apple.developer.kernel.increased-memory-limit</key><true/>");
    const string app = plist(
        "<key>com.apple.developer.kernel.increased-memory-limit</key><true/>"
        "<key>keychain-access-groups</key><array><string>OLD.com.example.shared</string></array>"
        "<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>");

    jvalue out;
    CHECK(out.read_plist(FSMatchAppEntitlements(profile, app, "TEAM")));
    // Identity keys always survive; undeclared capabilities are dropped.
    CHECK(out["application-identifier"].as_string() == "TEAM.app.example");
    CHECK(out.has("com.apple.developer.team-identifier"));
    CHECK(out.has("get-task-allow"));
    CHECK(!out.has("com.apple.developer.associated-domains"));
    CHECK(!out.has("com.apple.developer.healthkit"));
    // Declared capabilities keep the profile's value; keychain groups move to the profile team.
    CHECK(out["com.apple.developer.kernel.increased-memory-limit"].as_bool());
    CHECK(out["keychain-access-groups"].size() == 1);
    CHECK(out["keychain-access-groups"].at(0).as_string() == "TEAM.com.example.shared");
    // Nothing the profile lacks is invented.
    CHECK(!out.has("com.apple.developer.icloud-services"));
    // No app entitlements (unsigned input): today's behaviour, profile verbatim.
    CHECK(FSMatchAppEntitlements(profile, "", "TEAM") == profile);
    return 0;
}
