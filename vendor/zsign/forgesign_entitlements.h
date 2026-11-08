#ifndef FORGESIGN_ENTITLEMENTS_H
#define FORGESIGN_ENTITLEMENTS_H

#include "common/common.h"
#include "common/json.h"
#include "common/log.h"

// ForgeSign (opt-in): AltSign's entitlement rule. Keep a profile entitlement
// only when the original app declares it, keeping the profile's value; always
// keep the identity keys; point keychain groups at the profile team. zsign
// otherwise embeds every capability of the profile, which is what AltStore
// avoids. Falls back to the whole profile when the app declared nothing.
inline string FSMatchAppEntitlements(const string& strProfileEntitlements,
	const string& strAppEntitlements,
	const string& strTeamId)
{
	jvalue jvProfile;
	jvalue jvApp;
	if (strAppEntitlements.empty() || !jvProfile.read_plist(strProfileEntitlements) ||
		!jvApp.read_plist(strAppEntitlements) || !jvApp.is_object()) {
		return strProfileEntitlements;
	}

	vector<string> arrKeys;
	jvProfile.get_keys(arrKeys);
	for (const string& strKey : arrKeys) {
		if (!jvApp.has(strKey.c_str())) {
			if (strKey != "application-identifier" &&
				strKey != "com.apple.developer.team-identifier" &&
				strKey != "get-task-allow") {
				jvProfile.erase(strKey.c_str());
			}
			continue;
		}
		const jvalue& jvAppValue = jvApp.at(strKey.c_str());
		if (strKey == "keychain-access-groups" && jvAppValue.is_array() && !strTeamId.empty()) {
			jvalue jvGroups;
			for (size_t i = 0; i < jvAppValue.size(); ++i) {
				if (!jvAppValue.at(i).is_string()) continue;
				string strGroup = jvAppValue.at(i).as_string();
				size_t pos = strGroup.find('.');
				jvGroups.push_back(pos == string::npos ? strGroup : strTeamId + strGroup.substr(pos));
			}
			jvProfile[strKey.c_str()] = jvGroups;
		}
	}

	string strFiltered;
	jvProfile.style_write_plist(strFiltered);
	if (strFiltered.empty()) {
		return strProfileEntitlements;
	}
	ZLog::Print(">>> Signed with the app's own entitlements (AltStore rule)\n");
	return strFiltered;
}

#endif
