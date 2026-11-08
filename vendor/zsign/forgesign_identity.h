#ifndef FORGESIGN_IDENTITY_H
#define FORGESIGN_IDENTITY_H

#include <string>

// A wildcard profile authorizes the matching bundle ID, but the signed
// entitlement must use the concrete ID. Keep only the app-ID prefix (the
// component before the first dot): appending the whole partial pattern would
// duplicate part of the bundle ID.
inline std::string FSConcreteApplicationIdentifier(
    const std::string& profileIdentifier,
    const std::string& bundleIdentifier,
    const std::string& teamIdentifier)
{
    if (bundleIdentifier.empty()) return profileIdentifier;
    if (profileIdentifier == "*") {
        return teamIdentifier.empty() ? profileIdentifier
                                      : teamIdentifier + "." + bundleIdentifier;
    }
    if (profileIdentifier.size() < 2 ||
        profileIdentifier.compare(profileIdentifier.size() - 2, 2, ".*") != 0) {
        return profileIdentifier;
    }
    const std::string::size_type separator = profileIdentifier.find('.');
    if (separator == 0 || separator == std::string::npos) return profileIdentifier;
    return profileIdentifier.substr(0, separator) + "." + bundleIdentifier;
}

#endif
