import Foundation
import Network
import Security

/// TLS material for the local install server.
///
/// iOS OTA installation (`itms-services://`) only accepts manifests and IPAs
/// served over HTTPS with a certificate the device already trusts. ForgeSign
/// therefore serves its install payload over TLS using the publicly available
/// `*.backloop.dev` identity (BSD-3-Clause, https://backloop.dev): every
/// `*.backloop.dev` subdomain resolves to 127.0.0.1 / ::1, and the certificate
/// is issued by Let's Encrypt, so `https://install.backloop.dev:<port>` on the
/// device loops straight back into this app's listener with a valid handshake.
///
/// The leaf is issued by Let's Encrypt YR1 under ISRG Root YR. Root YR is not
/// in older iOS trust stores, so the PKCS#12 also carries the Root YR → ISRG
/// Root X1 cross-sign. `tlsParameters()` presents leaf + YR1 + that cross-sign
/// and deliberately omits Root X1 itself (sending a trust anchor breaks some
/// iOS TLS clients — which is what caused the 1.1.5 "TLS error" regression
/// vs the working 1.0 build).
enum InstallCertificate {
    /// Password protecting the embedded PKCS#12. Not secret — the identity is
    /// public loopback material shared by the backloop.dev project.
    static let password = "forgesign"

    /// The hostname clients use to reach this server. It must match the
    /// certificate's SAN and resolve to loopback via backloop.dev's DNS.
    static let hostname = "install.backloop.dev"

    /// Loads the embedded identity, or nil if parsing fails.
    static func loadIdentity() -> SecIdentity? {
        guard let items = importItems(),
              let rawIdentity = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID()
        else { return nil }
        return (rawIdentity as! SecIdentity)
    }

    /// Certificate chain for the identity (leaf first), as stored in the p12.
    static func loadChain() -> [SecCertificate] {
        (importItems()?.first?[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
    }

    /// NWParameters for an HTTPS listener using the embedded identity.
    static func tlsParameters() -> NWParameters? {
        guard let identity = loadIdentity() else { return nil }

        // Present intermediates so clients that do not fetch AIA (the iOS OTA
        // installer) can build a path to ISRG Root X1. Skip any self-signed
        // cert (subject == issuer) — that is the trust anchor and must not be
        // sent in the handshake.
        let intermediates = loadChain().dropFirst().filter { cert in
            let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data?
            let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?
            return subject != nil && subject != issuer
        }

        let secIdentity: sec_identity_t?
        if intermediates.isEmpty {
            secIdentity = sec_identity_create(identity)
        } else {
            secIdentity = sec_identity_create_with_certificates(identity, intermediates as CFArray)
                ?? sec_identity_create(identity)
        }
        guard let secIdentity else { return nil }

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

    /// PKCS#12: `*.backloop.dev` key + leaf + YR1 + Root YR→X1 cross-sign.
    /// Fetched from https://backloop.dev on 2026-08-06 (leaf through 2026-10-29).
    static let pkcs12Data: Data = {
        let base64 = base64Lines.joined()
        return Data(base64Encoded: base64) ?? Data()
    }()

    private static let base64Lines: [String] = [
        "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",
        "Mivn9Q86BBBO3/Z/098donGk2K8gGAihAgIIAA=="
    ]
}
