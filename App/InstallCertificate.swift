import Foundation
import Network
import Security

/// TLS material for the local install server.
///
/// iOS OTA installation (`itms-services://`) only accepts manifests and IPAs
/// served over HTTPS with a certificate the device already trusts. ForgeSign
/// therefore serves its install payload over TLS using the publicly available
/// `*.backloop.dev` identity (BSD-3-Clause, https://backloop.dev): every
/// `*.backloop.dev` subdomain resolves to 127.0.0.1, and the certificate is
/// issued by Let's Encrypt, so `https://install.backloop.dev:<port>` on the
/// device loops straight back into this app's listener with a valid, trusted
/// handshake. The same approach is used by other on-device signing tools
/// (e.g. Feather).
///
/// Chain note: the current leaf is issued by Let's Encrypt YR1, which chains
/// through ISRG Root YR. That root is not yet in older iOS trust stores, so
/// the embedded PKCS#12 also includes the Root YR → ISRG Root X1 cross-sign.
/// Presenting leaf + YR1 + cross-signed Root YR lets any device that trusts
/// ISRG Root X1 (iOS 10+) validate the handshake.
enum InstallCertificate {
    /// Password protecting the embedded PKCS#12. Not secret — the identity is
    /// public loopback material shared by the backloop.dev project.
    static let password = "forgesign"

    /// The hostname clients use to reach this server. It must match the
    /// certificate's SAN and resolve to 127.0.0.1 via backloop.dev's DNS.
    static let hostname = "install.backloop.dev"

    /// Loads the embedded identity, or nil if parsing fails.
    static func loadIdentity() -> SecIdentity? {
        guard let items = importItems(),
              let rawIdentity = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID()
        else { return nil }
        // CFGetTypeID above guarantees the value is a SecIdentity.
        return (rawIdentity as! SecIdentity)
    }

    /// The full certificate chain for the identity (leaf first).
    static func loadChain() -> [SecCertificate] {
        (importItems()?.first?[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
    }

    /// NWParameters for an HTTPS listener using the embedded identity.
    ///
    /// Uses `sec_identity_create_with_certificates` so the TLS handshake
    /// presents leaf + intermediates (YR1 and the Root YR → X1 cross-sign).
    /// Without the intermediates, clients that do not fetch AIA (notably the
    /// iOS OTA installer and OpenSSL's default verify) cannot build a path
    /// to ISRG Root X1 and abort the install.
    static func tlsParameters() -> NWParameters? {
        guard let identity = loadIdentity() else { return nil }
        let chain = loadChain()
        // dropFirst skips the leaf (already in the identity); pass only
        // intermediates so Network.framework doesn't duplicate the leaf.
        let intermediates = Array(chain.dropFirst()) as CFArray
        guard let secIdentity = sec_identity_create_with_certificates(identity, intermediates)
                ?? sec_identity_create(identity)
        else { return nil }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        return NWParameters(tls: options)
    }

    private static func importItems() -> [[String: Any]]? {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var rawItems: CFArray?
        guard SecPKCS12Import(pkcs12Data as CFData, options, &rawItems) == errSecSuccess,
              let items = rawItems as? [[String: Any]]
        else { return nil }
        return items
    }

    // MARK: Embedded identity

    /// PKCS#12 containing the `*.backloop.dev` private key, leaf certificate,
    /// Let's Encrypt YR1 intermediate, and the Root YR → ISRG Root X1
    /// cross-sign. Fetched from https://backloop.dev on 2026-08-06
    /// (leaf valid through 2026-10-29). If it ever expires, regenerate by
    /// downloading the current bundle from backloop.dev and rebuilding this
    /// file — include the X1 cross-sign so older iOS trust stores still work.
    static let pkcs12Data: Data = {
        let base64 = base64Lines.joined()
        return Data(base64Encoded: base64) ?? Data()
    }()

    private static let base64Lines: [String] = [
        "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",
        "n5gi15X/BBCvr9JlDFWghzKhzBSCM8mrAgIIAA=="
    ]
}
