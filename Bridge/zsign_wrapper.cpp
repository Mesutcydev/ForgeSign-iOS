#include "common.h"
#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include "macho.h"
#include "log.h"
#include <string>
#include <vector>
#include <time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/cms.h>

using namespace std;

// Reads a string value from a plist (XML or binary) using CoreFoundation.
static string FSReadPlistString(const string& path, const string& key)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return "";
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return ""; }
    vector<uint8_t> buf(sz);
    size_t rd = fread(buf.data(), 1, sz, f);
    fclose(f);
    if (rd != (size_t)sz) return "";

    CFDataRef data = CFDataCreate(NULL, buf.data(), sz);
    if (!data) return "";
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (!plist) return "";

    string result;
    if (CFDictionaryGetTypeID() == CFGetTypeID(plist)) {
        CFStringRef cfkey = CFStringCreateWithCString(NULL, key.c_str(), kCFStringEncodingUTF8);
        CFTypeRef val = CFDictionaryGetValue((CFDictionaryRef)plist, cfkey);
        if (val && CFStringGetTypeID() == CFGetTypeID(val)) {
            char tmp[1024];
            if (CFStringGetCString((CFStringRef)val, tmp, sizeof(tmp), kCFStringEncodingUTF8)) {
                result = tmp;
            }
        }
        CFRelease(cfkey);
    }
    CFRelease(plist);
    return result;
}

static bool FSReadProvisioningEntitlements(const string& profilePath, jvalue& entitlements)
{
    string profileData;
    if (!ZFile::ReadFile(profilePath.c_str(), profileData) || profileData.empty()) return false;
    string payload;
    if (!ZSignAsset::GetCMSContent(profileData, payload)) return false;
    jvalue profile;
    if (!profile.read_plist(payload) || !profile.has("Entitlements") ||
        !profile["Entitlements"].is_object()) return false;
    entitlements = profile["Entitlements"];
    return true;
}

static jvalue FSStringArrayFromEntitlement(const jvalue& entitlements, const char* key)
{
    jvalue values(jvalue::E_ARRAY);
    if (!entitlements.is_object() || !entitlements.has(key) || !entitlements.at(key).is_array()) {
        return values;
    }
    const jvalue& source = entitlements.at(key);
    for (size_t i = 0; i < source.size(); ++i) {
        if (source.at(i).is_string()) values.push_back(source.at(i).as_string());
    }
    return values;
}

static bool FSProfilePatternMatches(const string& applicationIdentifier, const string& bundleID)
{
    size_t dot = applicationIdentifier.find('.');
    string pattern = dot == string::npos ? applicationIdentifier : applicationIdentifier.substr(dot + 1);
    if (pattern == "*" || pattern == bundleID) return true;
    if (pattern.size() >= 2 && pattern.compare(pattern.size() - 2, 2, ".*") == 0) {
        string prefix = pattern.substr(0, pattern.size() - 2);
        return bundleID == prefix ||
            (bundleID.size() > prefix.size() && bundleID.compare(0, prefix.size(), prefix) == 0 &&
             bundleID[prefix.size()] == '.');
    }
    size_t patternStart = 0;
    size_t bundleStart = 0;
    while (patternStart < pattern.size() || bundleStart < bundleID.size()) {
        size_t patternEnd = pattern.find('.', patternStart);
        if (patternEnd == string::npos) patternEnd = pattern.size();
        size_t bundleEnd = bundleID.find('.', bundleStart);
        if (bundleEnd == string::npos) bundleEnd = bundleID.size();
        string patternPart = pattern.substr(patternStart, patternEnd - patternStart);
        string bundlePart = bundleID.substr(bundleStart, bundleEnd - bundleStart);
        if (patternPart != "*" && patternPart != bundlePart) return false;
        patternStart = patternEnd == pattern.size() ? pattern.size() : patternEnd + 1;
        bundleStart = bundleEnd == bundleID.size() ? bundleID.size() : bundleEnd + 1;
    }
    return patternStart == pattern.size() && bundleStart == bundleID.size();
}

static set<string> FSStringSet(const jvalue& value)
{
    set<string> result;
    if (!value.is_array()) return result;
    for (size_t i = 0; i < value.size(); ++i) {
        if (value.at(i).is_string()) result.insert(value.at(i).as_string());
    }
    return result;
}

static void FSAppendSignableBundle(jvalue& bundles,
                                   const string& appFolder,
                                   const string& bundleFolder,
                                   const string& kind)
{
    const string infoPath = bundleFolder + "/Info.plist";
    const string bundleID = FSReadPlistString(infoPath, "CFBundleIdentifier");
    const string executable = FSReadPlistString(infoPath, "CFBundleExecutable");
    if (bundleID.empty() || executable.empty()) return;

    jvalue bundle(jvalue::E_OBJECT);
    bundle["path"] = bundleFolder == appFolder ? "/" : bundleFolder.substr(appFolder.size() + 1);
    bundle["kind"] = kind;
    bundle["bundleIdentifier"] = bundleID;
    bundle["entitlementsAvailable"] = false;
    bundle["requiredAppGroups"] = jvalue(jvalue::E_ARRAY);
    bundle["requiredKeychainAccessGroups"] = jvalue(jvalue::E_ARRAY);

    jvalue entitlements;
    if (FSReadProvisioningEntitlements(bundleFolder + "/embedded.mobileprovision", entitlements)) {
        bundle["entitlementsAvailable"] = true;
        bundle["requiredAppGroups"] = FSStringArrayFromEntitlement(
            entitlements, "com.apple.security.application-groups");
        bundle["requiredKeychainAccessGroups"] = FSStringArrayFromEntitlement(
            entitlements, "keychain-access-groups");
    }
    bundles.push_back(bundle);
}

static bool FSSanitizeICloudEntitlements(string& entitlementData)
{
    if (entitlementData.empty()) return false;

    jvalue entitlements;
    if (!entitlements.read_plist(entitlementData)) {
        ZLog::Warn(">>> Could not parse profile entitlements; leaving them unchanged\n");
        return false;
    }

    const char* containerKeys[] = {
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.icloud-container-development-container-identifiers",
    };
    bool hasConcreteContainer = false;
    for (const char* key : containerKeys) {
        if (!entitlements.has(key) || !entitlements.at(key).is_array()) continue;
        const jvalue& containers = entitlements.at(key);
        for (size_t i = 0; i < containers.size(); ++i) {
            if (!containers.at(i).is_string()) continue;
            const string identifier = containers.at(i).as_string();
            if (identifier.find_first_not_of(" \t\r\n") == string::npos ||
                identifier.find('*') != string::npos) {
                continue;
            }
            hasConcreteContainer = true;
            break;
        }
        if (hasConcreteContainer) break;
    }

    if (hasConcreteContainer) return false;

    bool changed = false;
    for (const char* key : containerKeys) {
        if (entitlements.has(key)) {
            entitlements.erase(key);
            changed = true;
        }
    }
    const char* placeholderKeys[] = {
        "com.apple.developer.icloud-services",
        "com.apple.developer.ubiquity-kvstore-identifier",
        "com.apple.developer.icloud-container-environment",
    };
    for (const char* key : placeholderKeys) {
        if (entitlements.has(key)) {
            entitlements.erase(key);
            changed = true;
        }
    }
    if (!changed) return false;

    entitlementData.clear();
    entitlements.style_write_plist(entitlementData);
    ZLog::Print(">>> Stripped unusable iCloud entitlements (Files picker fix)\n");
    return true;
}

static bool FSValidateExtractedIPA(const string& folder, string& appFolder, string& error)
{
    const string payload = folder + "/Payload";
    if (!ZFile::IsFolder(payload.c_str())) {
        error = "IPA is missing a Payload directory.";
        return false;
    }

    size_t appCount = 0;
    ZFile::EnumFolder(payload.c_str(), false, NULL, [&](bool bFolder, const string& path) {
        if (bFolder && ZFile::IsPathSuffix(path, ".app")) {
            ++appCount;
            appFolder = path;
        }
        return false;
    });
    if (appCount != 1) {
        error = appCount == 0 ? "IPA must contain one Payload/*.app bundle."
                              : "IPA contains more than one Payload/*.app bundle.";
        return false;
    }

    const string executable = FSReadPlistString(appFolder + "/Info.plist", "CFBundleExecutable");
    if (!ZFile::IsRegularFile((appFolder + "/Info.plist").c_str()) || executable.empty() ||
        !ZFile::IsRegularFile((appFolder + "/" + executable).c_str())) {
        error = "IPA app bundle is missing Info.plist or its executable.";
        return false;
    }
    return true;
}

// ForgeSign on-device signing bridge.
// Signs an IPA using zsign (userspace codesign) with a .p12 + password + profile.
// Returns 0 on success, non-zero on failure. Writes a short status message into
// msgBuf (NUL-terminated) for the UI.
static int FS_SignIPA(const char* ipaPath,
                      const char* p12Path,
                      const char* password,
                      const char* profilePaths,
                      const char* bundleId,
                      const char* outputPath,
                      const char* tempFolder,
                      int removeExtensions,
                      int enableDocuments,
                      char* msgBuf,
                      int msgBufLen,
                      char* bundleIdBuf,
                      int bundleIdBufLen,
                      char* versionBuf,
                      int versionBufLen)
{
    auto setMsg = [&](const string& m) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", m.c_str());
        }
    };

    ZLog::SetLogLever(ZLog::E_WARN);

    string strIpa = ipaPath ? ipaPath : "";
    string strP12 = p12Path ? p12Path : "";
    string strPassword = password ? password : "";
    string strProfiles = profilePaths ? profilePaths : "";
    string strBundleId = bundleId ? bundleId : "";
    string strOutput = outputPath ? outputPath : "";
    string strTemp = tempFolder ? tempFolder : "";

    if (strIpa.empty() || strP12.empty() || strProfiles.empty() || strOutput.empty()) {
        setMsg("Missing input path, certificate, profile, or output path.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str())) {
        setMsg("IPA not found: " + strIpa);
        return 2;
    }
    if (!ZFile::IsFileExists(strP12.c_str())) {
        setMsg("Certificate (.p12) not found.");
        return 3;
    }
    if (!ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 5;
    }
    if (strTemp.empty() || !ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temp folder.");
        return 6;
    }

    list<ZSignAsset> signAssets;
    size_t start = 0;
    while (start <= strProfiles.size()) {
        size_t end = strProfiles.find('\n', start);
        if (end == string::npos) end = strProfiles.size();
        string profile = strProfiles.substr(start, end - start);
        if (profile.empty() || !ZFile::IsFileExists(profile.c_str())) {
            setMsg("Provisioning profile not found.");
            return 4;
        }
        signAssets.emplace_back();
        if (!signAssets.back().Init("", strP12, profile, "", strPassword, false, true, false)) {
            setMsg("Failed to load certificate/profile. Check the P12 password and that the profile matches the certificate.");
            return 10;
        }
        FSSanitizeICloudEntitlements(signAssets.back().m_strEntitleData);
        if (end == strProfiles.size()) break;
        start = end + 1;
    }
    if (signAssets.empty()) {
        setMsg("No provisioning profiles were supplied.");
        return 4;
    }

    // Extract IPA to a working folder.
    string strFolder = ZFile::GetRealPathV("%s/fs_folder_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA.");
        return 11;
    }
    string extractedApp;
    string structureError;
    if (!FSValidateExtractedIPA(strFolder, extractedApp, structureError)) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg(structureError);
        return 11;
    }

    // Sign the folder.
    ZBundle bundle;
    bundle.m_bEnableDocuments = (enableDocuments != 0);
    bundle.m_bRemoveExtensions = (removeExtensions != 0);
    bundle.m_bRemoveWatchApp = false;
    bundle.m_bRemoveUISupportedDevices = false;
    bundle.m_bInjectExtensions = false;

    vector<string> arrDylibs;
    vector<string> arrRemoveDylibs;
    bool bRet = bundle.SignFolder(&signAssets, strFolder, strBundleId, "", "",
                                  arrDylibs, arrRemoveDylibs,
                                  true,   // force
                                  false,  // weak inject
                                  false,  // cache
                                  false); // remove provision
    if (!bRet) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg(bundle.m_strError.empty()
            ? "Signing failed while processing an executable or sealed resource."
            : bundle.m_strError);
        return 12;
    }

    // Report the signed bundle identifier and version (needed for the install manifest).
    if (bundleIdBuf && bundleIdBufLen > 0) {
        string signedId = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleIdentifier");
        snprintf(bundleIdBuf, bundleIdBufLen, "%s", signedId.c_str());
    }
    if (versionBuf && versionBufLen > 0) {
        string signedVersion = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleVersion");
        if (signedVersion.empty()) {
            signedVersion = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleShortVersionString");
        }
        snprintf(versionBuf, versionBufLen, "%s", signedVersion.c_str());
    }

    // Repackage to IPA.
    size_t pos = bundle.m_strAppFolder.rfind("Payload");
    if (string::npos == pos || 0 == pos) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Could not locate Payload directory after signing.");
        return 13;
    }
    string strBaseFolder = bundle.m_strAppFolder.substr(0, pos - 1);
    if (!Zip::Archive(strBaseFolder.c_str(), strOutput.c_str(), 0)) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Failed to package the signed IPA.");
        return 14;
    }

    ZFile::RemoveFolder(strFolder.c_str());
    setMsg("Signed OK: " + strOutput);
    return 0;
}

extern "C" int forgesign_sign_ipa(const char* ipaPath,
                                   const char* p12Path,
                                   const char* password,
                                   const char* provPath,
                                   const char* bundleId,
                                   const char* outputPath,
                                   const char* tempFolder,
                                   int removeExtensions,
                                   int enableDocuments,
                                   char* msgBuf,
                                   int msgBufLen,
                                   char* bundleIdBuf,
                                   int bundleIdBufLen,
                                   char* versionBuf,
                                   int versionBufLen)
{
    return FS_SignIPA(ipaPath, p12Path, password, provPath, bundleId, outputPath, tempFolder,
                      removeExtensions, enableDocuments, msgBuf, msgBufLen,
                      bundleIdBuf, bundleIdBufLen, versionBuf, versionBufLen);
}

extern "C" int forgesign_sign_ipa_profiles(const char* ipaPath,
                                            const char* p12Path,
                                            const char* password,
                                            const char* profilePaths,
                                            const char* bundleId,
                                            const char* outputPath,
                                            const char* tempFolder,
                                            int removeExtensions,
                                            int enableDocuments,
                                            char* msgBuf,
                                            int msgBufLen,
                                            char* bundleIdBuf,
                                            int bundleIdBufLen,
                                            char* versionBuf,
                                            int versionBufLen)
{
    return FS_SignIPA(ipaPath, p12Path, password, profilePaths, bundleId, outputPath, tempFolder,
                      removeExtensions, enableDocuments, msgBuf, msgBufLen,
                      bundleIdBuf, bundleIdBufLen, versionBuf, versionBufLen);
}

// Read-only IPA inspection used by the UI before signing. This deliberately
// has its own bridge entry point: it extracts into a disposable folder and
// never creates, modifies, signs, or repackages an IPA.
static bool FSHasMachOMagic(const string& path)
{
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) return false;
    uint32_t magic = 0;
    bool ok = (fread(&magic, sizeof(magic), 1, fp) == 1) &&
              (magic == MH_MAGIC || magic == MH_CIGAM ||
               magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
               magic == FAT_MAGIC || magic == FAT_CIGAM);
    fclose(fp);
    return ok;
}

static bool FSIsTopLevelAppExtension(const string& appFolder, const string& path)
{
    if (!ZFile::IsPathSuffix(path, ".appex") || path.size() <= appFolder.size() + 1) {
        return false;
    }
    string relative = path.substr(appFolder.size() + 1);
    if (1 != count(relative.begin(), relative.end(), '/')) {
        return false;
    }
    return (0 == relative.rfind("PlugIns/", 0) ||
            0 == relative.rfind("Extensions/", 0));
}

static bool FSInjectMachO(const string& path,
                          const string& loadPath,
                          string& error)
{
    if (!FSHasMachOMagic(path)) {
        error = "Target is not a Mach-O executable: " + path;
        return false;
    }

    ZMachO macho;
    if (!macho.Init(path.c_str())) {
        error = "Could not parse Mach-O executable: " + path;
        return false;
    }
    if (macho.IsEncrypted()) {
        error = "Encrypted Mach-O cannot be injected: " + path;
        macho.Free();
        return false;
    }

    bool injected = macho.InjectDylib(false, loadPath.c_str());
    bool closed = macho.Free();
    if (!injected || !closed) {
        error = "Could not add the dylib load command. The executable may not have enough load-command space: " + path;
        return false;
    }
    return true;
}

// Prepares a disposable IPA for the existing signing pass. The original IPA
// is never modified and no provisioning/signature work happens here.
extern "C" int forgesign_inject_dylib_ipa(const char* ipaPath,
                                          const char* dylibPath,
                                          const char* outputPath,
                                          const char* tempFolder,
                                          int injectExtensions,
                                          char* msgBuf,
                                          int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", message.c_str());
        }
    };

    string strIpa = ipaPath ? ipaPath : "";
    string strDylib = dylibPath ? dylibPath : "";
    string strOutput = outputPath ? outputPath : "";
    string strTemp = tempFolder ? tempFolder : "";

    if (strIpa.empty() || strDylib.empty() || strOutput.empty() || strTemp.empty()) {
        setMsg("Missing IPA, dylib, output, or temporary folder.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str()) || !ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 2;
    }
    if (!ZFile::IsFileExists(strDylib.c_str()) ||
        !ZFile::IsPathSuffix(strDylib, ".dylib") ||
        !FSHasMachOMagic(strDylib)) {
        setMsg("The selected file is not a valid Mach-O .dylib.");
        return 3;
    }
    if (!ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temporary folder.");
        return 4;
    }

    ZMachO dylib;
    if (!dylib.Init(strDylib.c_str())) {
        setMsg("Could not parse the selected dylib.");
        return 5;
    }
    if (dylib.IsEncrypted()) {
        dylib.Free();
        setMsg("The selected dylib is encrypted and cannot be injected.");
        return 6;
    }
    dylib.Free();

    string strFolder = ZFile::GetRealPathV("%s/fs_inject_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA for dylib injection.");
        return 7;
    }

    auto fail = [&](int code, const string& message) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg(message);
        return code;
    };

    string appFolder;
    string structureError;
    if (!FSValidateExtractedIPA(strFolder, appFolder, structureError)) {
        return fail(8, structureError);
    }

    string dylibName = ZUtil::GetBaseName(strDylib.c_str());
    if (dylibName.empty() || dylibName == "." || dylibName == "..") {
        return fail(9, "Could not determine the dylib filename.");
    }

    string bundledDylib = appFolder + "/" + dylibName;
    if (ZFile::IsFileExists(bundledDylib.c_str())) {
        return fail(10, "The app already contains a file named " + dylibName + ". Rename the dylib before injecting.");
    }
    if (!ZFile::CopyFile(strDylib.c_str(), bundledDylib.c_str())) {
        return fail(11, "Could not copy the dylib into the app bundle.");
    }

    string executable = FSReadPlistString(appFolder + "/Info.plist", "CFBundleExecutable");
    if (executable.empty()) {
        return fail(12, "The app bundle has no CFBundleExecutable.");
    }

    string error;
    if (!FSInjectMachO(appFolder + "/" + executable,
                       "@executable_path/" + dylibName,
                       error)) {
        return fail(13, error);
    }

    int injectedTargets = 1;
    if (injectExtensions != 0) {
        vector<string> extensions;
        ZFile::EnumFolder(appFolder.c_str(), true, NULL, [&](bool bFolder, const string& path) {
            if (bFolder && FSIsTopLevelAppExtension(appFolder, path)) {
                extensions.push_back(path);
            }
            return false;
        });

        for (const string& extension : extensions) {
            string extensionExecutable = FSReadPlistString(extension + "/Info.plist", "CFBundleExecutable");
            if (extensionExecutable.empty()) {
                return fail(14, "An app extension has no CFBundleExecutable: " + extension);
            }

            string relative = extension.substr(appFolder.size() + 1);
            string prefix;
            for (size_t i = 0, n = 1 + (size_t)count(relative.begin(), relative.end(), '/'); i < n; i++) {
                prefix += "../";
            }
            string extensionLoadPath = "@executable_path/" + prefix + dylibName;
            if (!FSInjectMachO(extension + "/" + extensionExecutable,
                               extensionLoadPath,
                               error)) {
                return fail(15, error);
            }
            injectedTargets += 1;
        }
    }

    size_t payloadPos = appFolder.rfind("Payload");
    if (string::npos == payloadPos || 0 == payloadPos) {
        return fail(16, "Could not locate the Payload directory after injection.");
    }
    string baseFolder = appFolder.substr(0, payloadPos - 1);
    ZFile::RemoveFile(strOutput.c_str());
    if (!Zip::Archive(baseFolder.c_str(), strOutput.c_str(), 0)) {
        return fail(17, "Failed to package the IPA after dylib injection.");
    }

    ZFile::RemoveFolder(strFolder.c_str());
    setMsg("Prepared IPA with " + dylibName + " in " + to_string(injectedTargets) + " executable(s).");
    return 0;
}

extern "C" int forgesign_inspect_ipa(const char* ipaPath,
                                      const char* tempFolder,
                                      char* jsonBuf,
                                      int jsonBufLen,
                                      char* msgBuf,
                                      int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", message.c_str());
        }
    };

    string strIpa = ipaPath ? ipaPath : "";
    string strTemp = tempFolder ? tempFolder : "";
    if (strIpa.empty() || strTemp.empty()) {
        setMsg("Missing IPA or temporary folder.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str())) {
        setMsg("IPA not found.");
        return 2;
    }
    if (!ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 3;
    }
    if (!ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temporary folder.");
        return 4;
    }

    string strFolder = ZFile::GetRealPathV("%s/fs_inspect_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA for inspection.");
        return 5;
    }

    string appFolder;
    string structureError;
    if (!FSValidateExtractedIPA(strFolder, appFolder, structureError)) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg(structureError);
        return 6;
    }

    jvalue result(jvalue::E_OBJECT);
    string appName = FSReadPlistString(appFolder + "/Info.plist", "CFBundleDisplayName");
    if (appName.empty()) appName = FSReadPlistString(appFolder + "/Info.plist", "CFBundleName");
    if (appName.empty()) appName = ZUtil::GetBaseName(appFolder.c_str());

    result["appName"] = appName;
    result["bundleIdentifier"] = FSReadPlistString(appFolder + "/Info.plist", "CFBundleIdentifier");
    result["shortVersion"] = FSReadPlistString(appFolder + "/Info.plist", "CFBundleShortVersionString");
    result["buildVersion"] = FSReadPlistString(appFolder + "/Info.plist", "CFBundleVersion");
    result["minimumOSVersion"] = FSReadPlistString(appFolder + "/Info.plist", "MinimumOSVersion");
    result["nestedBundleCount"] = 0;
    result["extensionCount"] = 0;
    result["frameworkCount"] = 0;
    result["watchAppCount"] = 0;
    result["totalMachOCount"] = 0;
    result["signedMachOCount"] = 0;
    result["encryptedExecutableCount"] = 0;
    result["encryptedPaths"] = jvalue(jvalue::E_ARRAY);
    result["bundles"] = jvalue(jvalue::E_ARRAY);
    FSAppendSignableBundle(result["bundles"], appFolder, appFolder, "app");

    ZFile::EnumFolder(appFolder.c_str(), true, NULL, [&](bool bFolder, const string& path) {
        if (bFolder) {
            if (ZFile::IsPathSuffix(path, ".app") ||
                ZFile::IsPathSuffix(path, ".appex") ||
                ZFile::IsPathSuffix(path, ".framework") ||
                ZFile::IsPathSuffix(path, ".xctest")) {
                result["nestedBundleCount"] = result["nestedBundleCount"].as_int() + 1;
            }
            if (ZFile::IsPathSuffix(path, ".appex")) {
                result["extensionCount"] = result["extensionCount"].as_int() + 1;
            }
            if (ZFile::IsPathSuffix(path, ".framework")) {
                result["frameworkCount"] = result["frameworkCount"].as_int() + 1;
            }
            if (ZFile::IsPathSuffix(path, ".app") &&
                (path.find("/Watch/") != string::npos ||
                 path.find("/WatchKit/") != string::npos)) {
                result["watchAppCount"] = result["watchAppCount"].as_int() + 1;
            }
            if (ZFile::IsPathSuffix(path, ".appex")) {
                FSAppendSignableBundle(result["bundles"], appFolder, path, "extension");
            } else if (ZFile::IsPathSuffix(path, ".app")) {
                string kind = "nestedApp";
                if (path.find("/Watch/") != string::npos || path.find("/WatchKit/") != string::npos) {
                    kind = "watchApp";
                } else if (path.find("/AppClips/") != string::npos) {
                    kind = "appClip";
                }
                FSAppendSignableBundle(result["bundles"], appFolder, path, kind);
            }
            return false;
        }

        if (!ZFile::IsRegularFile(path.c_str()) || !FSHasMachOMagic(path)) {
            return false;
        }

        ZMachO macho;
        if (!macho.Init(path.c_str())) {
            return false;
        }

        result["totalMachOCount"] = result["totalMachOCount"].as_int() + 1;
        if (macho.CheckSignature()) {
            result["signedMachOCount"] = result["signedMachOCount"].as_int() + 1;
        }
        if (macho.IsEncrypted()) {
            result["encryptedExecutableCount"] = result["encryptedExecutableCount"].as_int() + 1;
            if (result["encryptedPaths"].size() < 8) {
                result["encryptedPaths"].push_back(path.substr(appFolder.size() + 1));
            }
        }
        return false;
    });

    string json;
    result.style_write(json);
    if (!jsonBuf || jsonBufLen <= 0 || json.size() + 1 > (size_t)jsonBufLen) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Inspection result was too large.");
        return 7;
    }
    snprintf(jsonBuf, jsonBufLen, "%s", json.c_str());
    ZFile::RemoveFolder(strFolder.c_str());
    setMsg("IPA inspected.");
    return 0;
}

// Validates a PKCS#12 with the same OpenSSL engine used for signing (the
// system SecPKCS12Import rejects OpenSSL-3 style AES-256 p12 files) and
// reports subject CN / O / OU plus the notAfter epoch for the UI.
static void FSCopyNameEntry(X509_NAME* name, int nid, char* buf, int len)
{
    if (!name || !buf || len <= 0) return;
    buf[0] = 0;
    int idx = X509_NAME_get_index_by_NID(name, nid, -1);
    if (idx < 0) return;
    X509_NAME_ENTRY* entry = X509_NAME_get_entry(name, idx);
    if (!entry) return;
    ASN1_STRING* data = X509_NAME_ENTRY_get_data(entry);
    if (!data) return;
    unsigned char* utf8 = NULL;
    int n = ASN1_STRING_to_UTF8(&utf8, data);
    if (n < 0 || !utf8) return;
    snprintf(buf, len, "%.*s", n, (const char*)utf8);
    OPENSSL_free(utf8);
}

extern "C" int forgesign_verify_ipa(const char* ipaPath,
                                      const char* tempFolder,
                                      char* msgBuf,
                                      int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) snprintf(msgBuf, msgBufLen, "%s", message.c_str());
    };
    string ipa = ipaPath ? ipaPath : "";
    string temp = tempFolder ? tempFolder : "";
    if (ipa.empty() || temp.empty() || !ZFile::IsFileExists(ipa.c_str()) || !ZFile::IsFolder(temp.c_str())) {
        setMsg("Signed IPA or verification folder is unavailable.");
        return 1;
    }
    string folder = ZFile::GetRealPathV("%s/fs_verify_%llu", temp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(ipa.c_str(), folder.c_str())) {
        setMsg("Signed IPA could not be extracted for verification.");
        return 2;
    }

    string appFolder;
    string structureError;
    if (!FSValidateExtractedIPA(folder, appFolder, structureError)) {
        ZFile::RemoveFolder(folder.c_str());
        setMsg(structureError);
        return 3;
    }

    bool ok = true;
    string failure;
    ZFile::EnumFolder(appFolder.c_str(), true, NULL, [&](bool bFolder, const string& path) {
        if (bFolder) return false;
        if (!ZFile::IsRegularFile(path.c_str()) || !FSHasMachOMagic(path)) return false;
        ZMachO macho;
        if (!macho.Init(path.c_str()) || !macho.CheckSignature()) {
            ok = false;
            failure = "An executable is not signed: " + path.substr(appFolder.size() + 1);
            return true;
        }
        if (macho.IsEncrypted()) {
            ok = false;
            failure = "An executable remains encrypted: " + path.substr(appFolder.size() + 1);
            return true;
        }
        return false;
    });

    if (ok) {
        vector<string> provisionedBundles;
        provisionedBundles.push_back(appFolder);
        ZFile::EnumFolder(appFolder.c_str(), true, NULL, [&](bool bFolder, const string& path) {
            if (bFolder && (ZFile::IsPathSuffix(path, ".appex") || ZFile::IsPathSuffix(path, ".app"))) {
                provisionedBundles.push_back(path);
            }
            return false;
        });
        for (const string& bundlePath : provisionedBundles) {
            if (!ZFile::IsFileExists((bundlePath + "/_CodeSignature/CodeResources").c_str())) {
                ok = false;
                failure = "Missing CodeResources: " + bundlePath.substr(appFolder.size() + 1);
                break;
            }
            if (!ZFile::IsFileExists((bundlePath + "/embedded.mobileprovision").c_str())) {
                ok = false;
                failure = "Missing embedded provisioning profile: " + bundlePath.substr(appFolder.size() + 1);
                break;
            }

            const string bundleID = FSReadPlistString(bundlePath + "/Info.plist", "CFBundleIdentifier");
            jvalue profileEntitlements;
            if (bundleID.empty() ||
                !FSReadProvisioningEntitlements(bundlePath + "/embedded.mobileprovision", profileEntitlements)) {
                ok = false;
                failure = "Invalid embedded provisioning profile: " + bundlePath.substr(appFolder.size() + 1);
                break;
            }
            const string applicationIdentifier = profileEntitlements["application-identifier"].as_cstr();
            const bool profileMatches = !applicationIdentifier.empty() &&
                FSProfilePatternMatches(applicationIdentifier, bundleID);
            if (!profileMatches && bundlePath == appFolder) {
                ok = false;
                failure = "Embedded profile does not match bundle ID " + bundleID + ".";
                break;
            }

            jvalue info;
            if (!info.read_plist_from_file("%s/Info.plist", bundlePath.c_str())) {
                ok = false;
                failure = "Could not read signed bundle metadata for " + bundleID + ".";
                break;
            }
            if (profileMatches) {
                const set<string> profileGroups = FSStringSet(
                    profileEntitlements["com.apple.security.application-groups"]);
                const set<string> metadataGroups = FSStringSet(info["ALTAppGroups"]);
                if (profileGroups != metadataGroups) {
                    ok = false;
                    failure = "ALTAppGroups does not match the signed profile for " + bundleID + ".";
                    break;
                }
            }
        }
    }

    ZFile::RemoveFolder(folder.c_str());
    if (!ok) {
        setMsg(failure.empty() ? "Signed IPA verification failed." : failure);
        return 4;
    }
    setMsg("Signed IPA verified.");
    return 0;
}

extern "C" int forgesign_p12_info(const char* p12Path,
                                  const char* password,
                                  char* cnBuf,
                                  int cnLen,
                                  char* oBuf,
                                  int oLen,
                                  char* ouBuf,
                                  int ouLen,
                                  long long* notAfterEpoch,
                                  char* fingerprintBuf,
                                  int fingerprintLen,
                                  char* msgBuf,
                                  int msgBufLen)
{
    auto setMsg = [&](const string& m) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", m.c_str());
        }
    };

    if (!p12Path) {
        setMsg("Missing certificate path.");
        return 1;
    }
    FILE* fp = fopen(p12Path, "rb");
    if (!fp) {
        setMsg("Certificate file could not be opened.");
        return 2;
    }
    PKCS12* p12 = d2i_PKCS12_fp(fp, NULL);
    fclose(fp);
    if (!p12) {
        setMsg("Not a valid PKCS#12 file.");
        return 3;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    int ok = PKCS12_parse(p12, password ? password : "", &pkey, &cert, NULL);
    PKCS12_free(p12);
    if (!ok || !cert) {
        if (pkey) EVP_PKEY_free(pkey);
        if (cert) X509_free(cert);
        setMsg("Wrong password, or not a valid signing certificate.");
        return 4;
    }

    X509_NAME* subj = X509_get_subject_name(cert);
    FSCopyNameEntry(subj, NID_commonName, cnBuf, cnLen);
    FSCopyNameEntry(subj, NID_organizationName, oBuf, oLen);
    FSCopyNameEntry(subj, NID_organizationalUnitName, ouBuf, ouLen);

    if (fingerprintBuf && fingerprintLen > 0) {
        fingerprintBuf[0] = 0;
        unsigned char digest[EVP_MAX_MD_SIZE];
        unsigned int digestLength = 0;
        if (X509_digest(cert, EVP_sha256(), digest, &digestLength)) {
            string fingerprint;
            static const char* hex = "0123456789abcdef";
            fingerprint.reserve(digestLength * 2);
            for (unsigned int i = 0; i < digestLength; ++i) {
                fingerprint.push_back(hex[(digest[i] >> 4) & 0x0f]);
                fingerprint.push_back(hex[digest[i] & 0x0f]);
            }
            snprintf(fingerprintBuf, fingerprintLen, "%s", fingerprint.c_str());
        }
    }

    if (notAfterEpoch) {
        *notAfterEpoch = 0;
        const ASN1_TIME* na = X509_get0_notAfter(cert);
        if (na) {
            struct tm tmv;
            memset(&tmv, 0, sizeof(tmv));
            if (ASN1_TIME_to_tm(na, &tmv)) {
                *notAfterEpoch = (long long)timegm(&tmv);
            }
        }
    }

    if (pkey) EVP_PKEY_free(pkey);
    X509_free(cert);
    return 0;
}

extern "C" int forgesign_profile_info(const char* profilePath,
                                      char* msgBuf,
                                      int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) snprintf(msgBuf, msgBufLen, "%s", message.c_str());
    };
    if (!profilePath) {
        setMsg("Missing provisioning profile path.");
        return 1;
    }

    FILE* fp = fopen(profilePath, "rb");
    if (!fp) {
        setMsg("Provisioning profile could not be opened.");
        return 2;
    }
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0) {
        fclose(fp);
        setMsg("Provisioning profile is empty.");
        return 3;
    }
    string data((size_t)size, '\0');
    size_t read = fread(&data[0], 1, data.size(), fp);
    fclose(fp);
    if (read != data.size()) {
        setMsg("Provisioning profile could not be read.");
        return 3;
    }

    BIO* input = BIO_new_mem_buf(data.data(), (int)data.size());
    CMS_ContentInfo* cms = input ? d2i_CMS_bio(input, NULL) : NULL;
    if (input) BIO_free(input);
    if (!cms) {
        setMsg("Provisioning profile is not a valid CMS container.");
        return 4;
    }

    BIO* content = BIO_new(BIO_s_mem());
    int verified = content && CMS_verify(cms, NULL, NULL, NULL, content, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY);
    if (!verified) {
        if (content) BIO_free(content);
        CMS_ContentInfo_free(cms);
        setMsg("Provisioning profile CMS signature is invalid.");
        return 5;
    }

    BUF_MEM* memory = NULL;
    BIO_get_mem_ptr(content, &memory);
    string plist = (memory && memory->data && memory->length)
        ? string(memory->data, memory->length) : string();
    BIO_free(content);
    CMS_ContentInfo_free(cms);

    jvalue profile;
    if (plist.empty() || !profile.read_plist(plist) || !profile.has("Entitlements") ||
        !profile["Entitlements"].is_object()) {
        setMsg("Provisioning profile payload is invalid.");
        return 6;
    }
    return 0;
}

extern "C" int forgesign_validate_signing_asset(const char* p12Path,
                                                  const char* password,
                                                  const char* profilePath,
                                                  char* msgBuf,
                                                  int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) snprintf(msgBuf, msgBufLen, "%s", message.c_str());
    };
    if (!p12Path || !profilePath) {
        setMsg("The certificate or provisioning profile is missing.");
        return 1;
    }
    ZSignAsset asset;
    if (!asset.Init("", p12Path, profilePath, "", password ? password : "", false, true, false)) {
        setMsg("The profile does not contain the certificate, or the P12 password is incorrect.");
        return 2;
    }
    setMsg("Certificate and profile match.");
    return 0;
}

// Returns the zsign version string.
extern "C" const char* forgesign_zsign_version(void)
{
    return "zsign-embedded";
}
