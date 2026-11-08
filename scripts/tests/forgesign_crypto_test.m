#import <Foundation/Foundation.h>
#import "ALTCertificate.h"
#include <OpenSSL/OpenSSL.h>
#include <openssl/cms.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <assert.h>
#include <string.h>

static NSData *p12Data(EVP_PKEY *key, X509 *certificate, BOOL legacy) {
    PKCS12 *container = PKCS12_create("fixture-pass", "ForgeSign fixture", key, certificate, NULL,
        legacy ? NID_pbe_WithSHA1And3_Key_TripleDES_CBC : 0,
        legacy ? NID_pbe_WithSHA1And40BitRC2_CBC : 0, 2048, 2048, 0);
    assert(container);
    unsigned char *bytes = NULL;
    int length = i2d_PKCS12(container, &bytes);
    assert(length > 0);
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    OPENSSL_free(bytes);
    PKCS12_free(container);
    return data;
}

int main(void) {
    @autoreleasepool {
        assert(forgesign_openssl_providers_ready());
        assert(OpenSSL_version_num() == OPENSSL_VERSION_NUMBER);
        EVP_PKEY *key = EVP_RSA_gen(2048);
        X509 *certificate = X509_new();
        assert(key && certificate);
        assert(X509_set_version(certificate, 2));
        assert(ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1));
        assert(X509_gmtime_adj(X509_getm_notBefore(certificate), -60));
        assert(X509_gmtime_adj(X509_getm_notAfter(certificate), 3600));
        assert(X509_set_pubkey(certificate, key));
        X509_NAME *name = X509_get_subject_name(certificate);
        assert(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
            (unsigned char *)"ForgeSign fixture", -1, -1, 0));
        assert(X509_set_issuer_name(certificate, name));
        assert(X509_sign(certificate, key, EVP_sha256()));

        for (NSNumber *legacy in @[@NO, @YES]) {
            NSData *data = p12Data(key, certificate, legacy.boolValue);
            ALTCertificate *parsed = [[ALTCertificate alloc] initWithP12Data:data password:@"fixture-pass"];
            assert(parsed && parsed.data.length && parsed.privateKey.length);
            assert([parsed.name isEqualToString:@"ForgeSign fixture"]);
            assert(![[ALTCertificate alloc] initWithP12Data:data password:@"incorrect"]);
            NSData *roundtrip = [parsed encryptedP12DataWithPassword:@"roundtrip"];
            assert(roundtrip.length);
            assert([[ALTCertificate alloc] initWithP12Data:roundtrip password:@"roundtrip"]);
        }
        assert(![[ALTCertificate alloc] initWithP12Data:[NSData data] password:nil]);
        assert(![[ALTCertificate alloc] initWithP12Data:[@"invalid P12" dataUsingEncoding:NSUTF8StringEncoding] password:nil]);

        const char *payload = "ForgeSign CMS fixture";
        BIO *input = BIO_new_mem_buf(payload, (int)strlen(payload));
        CMS_ContentInfo *cms = CMS_sign(certificate, key, NULL, input, CMS_BINARY);
        BIO *verified = BIO_new(BIO_s_mem());
        assert(cms && verified);
        assert(CMS_verify(cms, NULL, NULL, NULL, verified, CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY));
        char *bytes = NULL;
        long length = BIO_get_mem_data(verified, &bytes);
        assert(length == (long)strlen(payload) && memcmp(bytes, payload, (size_t)length) == 0);
        BIO_free(input);
        BIO_free(verified);
        CMS_ContentInfo_free(cms);
        EVP_PKEY_free(key);
        X509_free(certificate);
        puts("Shared OpenSSL: modern/legacy P12, invalid imports, AltSign roundtrip and CMS passed.");
    }
    return 0;
}
