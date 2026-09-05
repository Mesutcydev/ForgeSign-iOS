import Foundation

struct ProvisioningProviderBundle: Codable, Equatable, Sendable {
    let path: String
    let kind: SignableBundleInspection.Kind
    let originalBundleIdentifier: String
    let resolvedBundleIdentifier: String
    let requiredAppGroups: [String]
    let requiredKeychainAccessGroups: [String]
}

struct ProvisioningProviderRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let teamIdentifier: String?
    let certificateSHA256: String?
    let deviceIdentifier: String?
    let bundles: [ProvisioningProviderBundle]
}

struct ProvisioningProviderProfile: Codable, Equatable, Sendable {
    let filename: String
    let dataBase64: String
}

struct ProvisioningProviderResponse: Codable, Equatable, Sendable {
    let profiles: [ProvisioningProviderProfile]
    let message: String?
}

enum ProvisioningProviderError: LocalizedError, Sendable {
    case rejected(String)
    case invalidResponse
    case noProfiles

    var errorDescription: String? {
        switch self {
        case .rejected(let message):
            return message
        case .invalidResponse:
            return "The provisioning service returned an invalid response."
        case .noProfiles:
            return "The provisioning service did not return any profiles."
        }
    }
}

enum ProvisioningRequestFactory {
    static func request(inspection: IPAPreflight,
                        audit: ProvisioningAudit,
                        certificate: CertificateRecord?,
                        deviceIdentifier: String?) -> ProvisioningProviderRequest {
        let inspectionByPath = Dictionary(uniqueKeysWithValues: inspection.bundles.map { ($0.path, $0) })
        let bundles = audit.rows.compactMap { row -> ProvisioningProviderBundle? in
            guard row.state != .removed, let inspected = inspectionByPath[row.path] else { return nil }
            return ProvisioningProviderBundle(
                path: row.path,
                kind: row.kind,
                originalBundleIdentifier: row.originalBundleID,
                resolvedBundleIdentifier: row.resolvedBundleID,
                requiredAppGroups: inspected.requiredAppGroups,
                requiredKeychainAccessGroups: inspected.requiredKeychainAccessGroups
            )
        }
        return ProvisioningProviderRequest(
            protocolVersion: 1,
            teamIdentifier: certificate?.teamID,
            certificateSHA256: certificate?.certificateSHA256,
            deviceIdentifier: deviceIdentifier,
            bundles: bundles
        )
    }
}
