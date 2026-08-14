#ifndef ForgeSignBridge_h
#define ForgeSignBridge_h

#ifdef __cplusplus
extern "C" {
#endif

int forgesign_sign_ipa(const char* ipaPath,
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
                       int versionBufLen);

int forgesign_sign_ipa_profiles(const char* ipaPath,
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
                                int versionBufLen);

int forgesign_p12_info(const char* p12Path,
                       const char* password,
                       char* cnBuf,
                       int cnLen,
                       char* oBuf,
                       int oLen,
                       char* ouBuf,
                       int ouLen,
                       long long* notAfterEpoch,
                       char* msgBuf,
                       int msgBufLen);

int forgesign_profile_info(const char* profilePath,
                           char* msgBuf,
                           int msgBufLen);

int forgesign_inspect_ipa(const char* ipaPath,
                          const char* tempFolder,
                          char* jsonBuf,
                          int jsonBufLen,
                          char* msgBuf,
                          int msgBufLen);

int forgesign_verify_ipa(const char* ipaPath,
                         const char* tempFolder,
                         char* msgBuf,
                         int msgBufLen);

// Prepares a disposable IPA by copying a dylib into the app bundle and
// adding its load command to the app executable and, optionally, top-level
// app extensions. This does not sign the IPA; the existing signer consumes
// the prepared output afterward.
int forgesign_inject_dylib_ipa(const char* ipaPath,
                               const char* dylibPath,
                               const char* outputPath,
                               const char* tempFolder,
                               int injectExtensions,
                               char* msgBuf,
                               int msgBufLen);

const char* forgesign_zsign_version(void);

#ifdef __cplusplus
}
#endif

#endif /* ForgeSignBridge_h */
