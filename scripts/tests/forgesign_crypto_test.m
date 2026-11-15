/* Checks always run. assert() is removed under NDEBUG, which would skip setup
   that these tests depend on (audit B11). */
#include <stdio.h>
#include <stdlib.h>
#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #expr); exit(1); } } while (0)

#import <Foundation/Foundation.h>
#import "ALTCertificate.h"
#include <OpenSSL/OpenSSL.h>
#include <openssl/cms.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <string.h>

static NSData *p12Data(EVP_PKEY *key, X509 *certificate, BOOL legacy) {
    PKCS12 *container = PKCS12_create("fixture-pass", "ForgeSign fixture", key, certificate, NULL,
        legacy ? NID_pbe_WithSHA1And3_Key_TripleDES_CBC : 0,
        legacy ? NID_pbe_WithSHA1And40BitRC2_CBC : 0, 2048, 2048, 0);
    CHECK(container);
    unsigned char *bytes = NULL;
    int length = i2d_PKCS12(container, &bytes);
    CHECK(length > 0);
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    OPENSSL_free(bytes);
    PKCS12_free(container);
    return data;
}

int main(void) {
    @autoreleasepool {
        CHECK(forgesign_openssl_providers_ready());
        CHECK(OpenSSL_version_num() == OPENSSL_VERSION_NUMBER);
        EVP_PKEY *key = EVP_RSA_gen(2048);
        X509 *certificate = X509_new();
        CHECK(key && certificate);
        CHECK(X509_set_version(certificate, 2));
        CHECK(ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1));
        CHECK(X509_gmtime_adj(X509_getm_notBefore(certificate), -60));
        CHECK(X509_gmtime_adj(X509_getm_notAfter(certificate), 3600));
        CHECK(X509_set_pubkey(certificate, key));
        X509_NAME *name = X509_get_subject_name(certificate);
        CHECK(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
            (unsigned char *)"ForgeSign fixture", -1, -1, 0));
        CHECK(X509_set_issuer_name(certificate, name));
        CHECK(X509_sign(certificate, key, EVP_sha256()));

        for (NSNumber *legacy in @[@NO, @YES]) {
            NSData *data = p12Data(key, certificate, legacy.boolValue);
            ALTCertificate *parsed = [[ALTCertificate alloc] initWithP12Data:data password:@"fixture-pass"];
            CHECK(parsed && parsed.data.length && parsed.privateKey.length);
            CHECK([parsed.name isEqualToString:@"ForgeSign fixture"]);
            CHECK(![[ALTCertificate alloc] initWithP12Data:data password:@"incorrect"]);
            NSData *roundtrip = [parsed encryptedP12DataWithPassword:@"roundtrip"];
            CHECK(roundtrip.length);
            CHECK([[ALTCertificate alloc] initWithP12Data:roundtrip password:@"roundtrip"]);
        }
        CHECK(![[ALTCertificate alloc] initWithP12Data:[NSData data] password:nil]);
        CHECK(![[ALTCertificate alloc] initWithP12Data:[@"invalid P12" dataUsingEncoding:NSUTF8StringEncoding] password:nil]);

        const char *payload = "ForgeSign CMS fixture";
        BIO *input = BIO_new_mem_buf(payload, (int)strlen(payload));
        CMS_ContentInfo *cms = CMS_sign(certificate, key, NULL, input, CMS_BINARY);
        BIO *verified = BIO_new(BIO_s_mem());
        CHECK(cms && verified);
        CHECK(CMS_verify(cms, NULL, NULL, NULL, verified, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY));
        char *bytes = NULL;
        long length = BIO_get_mem_data(verified, &bytes);
        CHECK(length == (long)strlen(payload) && memcmp(bytes, payload, (size_t)length) == 0);
        BIO_free(input);
        BIO_free(verified);
        CMS_ContentInfo_free(cms);
        EVP_PKEY_free(key);
        X509_free(certificate);
        puts("Shared OpenSSL: modern/legacy P12, invalid imports, AltSign roundtrip and CMS passed.");
    }
    return 0;
}
