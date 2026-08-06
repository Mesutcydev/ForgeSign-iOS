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

const char* forgesign_zsign_version(void);

#ifdef __cplusplus
}
#endif

#endif /* ForgeSignBridge_h */
