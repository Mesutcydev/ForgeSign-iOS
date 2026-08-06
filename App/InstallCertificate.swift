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
enum InstallCertificate {
    /// Password protecting the embedded PKCS#12. Not secret - the identity is
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
    static func tlsParameters() -> NWParameters? {
        guard let identity = loadIdentity(),
              let secIdentity = sec_identity_create(identity)
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
    /// and Let's Encrypt intermediate. Fetched from https://backloop.dev on
    /// 2026-08-05 (certificate valid through 2026-10-29). If it ever expires,
    /// regenerate by downloading the current bundle from backloop.dev and
    /// rebuilding this file.
    static let pkcs12Data: Data = {
        let base64 = base64Lines.joined()
        return Data(base64Encoded: base64) ?? Data()
    }()

    private static let base64Lines: [String] = [
        "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"
    ]
}
