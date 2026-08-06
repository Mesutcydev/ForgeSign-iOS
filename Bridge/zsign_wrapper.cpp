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
