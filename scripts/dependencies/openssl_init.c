#include <openssl/crypto.h>
#include <openssl/provider.h>

// Both zsign and AltSign load this one framework. Keep providers alive for the
// process, including legacy RC2/3DES PKCS#12 files, without external modules or
// loading an openssl.cnf from outside the app.
static OSSL_PROVIDER *default_provider;
static OSSL_PROVIDER *legacy_provider;

__attribute__((constructor)) static void forgesign_openssl_initialize(void)
{
    OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
    default_provider = OSSL_PROVIDER_load(NULL, "default");
    legacy_provider = OSSL_PROVIDER_load(NULL, "legacy");
}

int forgesign_openssl_providers_ready(void)
{
    return default_provider != NULL && legacy_provider != NULL;
}
