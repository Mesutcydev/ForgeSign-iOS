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

// ForgeSign on-device signing bridge.
// Signs an IPA using zsign (userspace codesign) with a .p12 + password + profile.
// Returns 0 on success, non-zero on failure. Writes a short status message into
// msgBuf (NUL-terminated) for the UI.
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
    auto setMsg = [&](const string& m) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", m.c_str());
        }
    };

    ZLog::SetLogLever(ZLog::E_WARN);

    string strIpa = ipaPath ? ipaPath : "";
    string strP12 = p12Path ? p12Path : "";
    string strPassword = password ? password : "";
    string strProv = provPath ? provPath : "";
    string strBundleId = bundleId ? bundleId : "";
    string strOutput = outputPath ? outputPath : "";
    string strTemp = tempFolder ? tempFolder : "";

    if (strIpa.empty() || strP12.empty() || strProv.empty() || strOutput.empty()) {
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
    if (!ZFile::IsFileExists(strProv.c_str())) {
        setMsg("Provisioning profile not found.");
        return 4;
    }
    if (!ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 5;
    }
    if (strTemp.empty() || !ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temp folder.");
        return 6;
    }

    // Init signing asset from p12 + password + profile.
    ZSignAsset zsa;
    if (!zsa.Init("", strP12, strProv, "", strPassword, false, true, false)) {
        setMsg("Failed to load certificate/profile. Check the P12 password and that the profile matches the certificate.");
        return 10;
    }

    // Fat wildcard profiles often ship empty iCloud/ubiquity container lists
    // with icloud-services=*. Stamping those onto an app that never used iCloud
    // breaks UIDocumentPicker (Open enabled, does nothing) after resign, while
    // AltServer's lean profiles do not. Strip the empty-container iCloud keys.
    if (!zsa.m_strEntitleData.empty()) {
        jvalue jvEnt;
        if (jvEnt.read_plist(zsa.m_strEntitleData)) {
            auto emptyArray = [](jvalue& v) {
                return !v.is_array() || v.size() == 0;
            };
            bool changed = false;
            const char* containerKeys[] = {
                "com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.ubiquity-container-identifiers",
                "com.apple.developer.icloud-container-development-container-identifiers",
            };
            bool containersEmpty = true;
            bool hadContainerKey = false;
            for (const char* key : containerKeys) {
                if (!jvEnt.has(key)) continue;
                hadContainerKey = true;
                if (!emptyArray(jvEnt[key])) {
                    containersEmpty = false;
                    break;
                }
            }
            if (hadContainerKey && containersEmpty) {
                for (const char* key : containerKeys) {
                    if (jvEnt.has(key)) {
                        jvEnt.erase(key);
                        changed = true;
                    }
                }
                if (jvEnt.has("com.apple.developer.icloud-services")) {
                    jvEnt.erase("com.apple.developer.icloud-services");
                    changed = true;
                }
                if (jvEnt.has("com.apple.developer.ubiquity-kvstore-identifier")) {
                    // Keep kvstore only when real containers exist.
                    jvEnt.erase("com.apple.developer.ubiquity-kvstore-identifier");
                    changed = true;
                }
            }
            if (changed) {
                zsa.m_strEntitleData.clear();
                jvEnt.style_write_plist(zsa.m_strEntitleData);
                ZLog::Print(">>> Stripped empty iCloud container entitlements (Files picker fix)\n");
            }
        }
    }

    // Extract IPA to a working folder.
    string strFolder = ZFile::GetRealPathV("%s/fs_folder_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA.");
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
    bool bRet = bundle.SignFolder(&zsa, strFolder, strBundleId, "", "",
                                  arrDylibs, arrRemoveDylibs,
                                  true,   // force
                                  false,  // weak inject
                                  false,  // cache
                                  false); // remove provision
    if (!bRet) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Signing failed. See log for details.");
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

static string FSFindPayloadApp(const string& folder)
{
    string payload = folder + "/Payload";
    string appFolder;
    ZFile::EnumFolder(payload.c_str(), false, NULL, [&](bool bFolder, const string& path) {
        if (bFolder && ZFile::IsPathSuffix(path, ".app")) {
            appFolder = path;
            return true;
        }
        return false;
    });
    return appFolder;
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

    string appFolder = FSFindPayloadApp(strFolder);
    if (appFolder.empty()) {
        return fail(8, "No Payload/*.app bundle was found.");
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

    string appFolder = FSFindPayloadApp(strFolder);
    if (appFolder.empty()) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("No Payload/*.app bundle was found.");
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

extern "C" int forgesign_p12_info(const char* p12Path,
                                  const char* password,
                                  char* cnBuf,
                                  int cnLen,
                                  char* oBuf,
                                  int oLen,
                                  char* ouBuf,
                                  int ouLen,
                                  long long* notAfterEpoch,
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

// Returns the zsign version string.
extern "C" const char* forgesign_zsign_version(void)
{
    return "zsign-embedded";
}
