import Foundation
import Security
import UIKit

#if canImport(AltSign)
@preconcurrency import AltSign

extension ALTAccount: @retroactive @unchecked Sendable {}
extension ALTAnisetteData: @retroactive @unchecked Sendable {}
extension ALTAppleAPISession: @retroactive @unchecked Sendable {}
extension ALTTeam: @retroactive @unchecked Sendable {}
extension ALTDevice: @retroactive @unchecked Sendable {}
extension ALTCertificate: @retroactive @unchecked Sendable {}
extension ALTAppID: @retroactive @unchecked Sendable {}
extension ALTAppGroup: @retroactive @unchecked Sendable {}
extension ALTProvisioningProfile: @retroactive @unchecked Sendable {}
#endif

struct AltServerProvisioningResult: Sendable {
    let certificateData: Data
    let certificatePassword: String
    let profiles: [ProvisioningProviderProfile]
    let rootBundleIdentifier: String
    let teamIdentifier: String
}

enum AltServerProvisioningError: LocalizedError, Sendable {
    case unavailable
    case missingCredentials
    case missingDeviceIdentifier
    case invalidAnisetteData
    case authenticationFailed(String)
    case noTeam
    case certificateConflict
    case certificateCreationFailed
    case deviceRegistrationFailed(String)
    case appIDFailed(String, String)
    case appGroupFailed(String, String)
    case profileFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple-account provisioning is unavailable in this build."
        case .missingCredentials:
            return "Enter your Apple Account email and password."
        case .missingDeviceIdentifier:
            return "Enter this iPhone or iPad’s UDID. If AltStore installed ForgeSign, reinstall this build through AltStore so it can inject the UDID automatically."
        case .invalidAnisetteData:
            return "AltServer returned anisette data that AltSign could not use."
        case .authenticationFailed(let detail):
            return "Apple Account sign-in failed: \(detail)"
        case .noTeam:
            return "This Apple Account has no development team."
        case .certificateConflict:
            return "This team already has a development certificate, but ForgeSign does not have its private key. ForgeSign did not revoke it because that could break AltStore and apps signed with it. Use a matching imported P12, a different Apple Account, or the manual profile mode."
        case .certificateCreationFailed:
            return "Apple did not return a usable development certificate and private key."
        case .deviceRegistrationFailed(let detail):
            return "The device could not be registered: \(detail)"
        case .appIDFailed(let bundleID, let detail):
            return "App ID \(bundleID) could not be prepared: \(detail)"
        case .appGroupFailed(let groupID, let detail):
            return "App Group \(groupID) could not be prepared: \(detail)"
        case .profileFailed(let bundleID, let detail):
            return "A profile for \(bundleID) could not be created: \(detail)"
        }
    }
}

@MainActor
final class AltServerProvisioningService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case authenticating
        case registeringDevice
        case preparingCertificate
        case preparingProfiles(Int, Int)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var verificationCode = ""
    @Published var isRequestingVerificationCode = false

    private var verificationReply: ((String?) -> Void)?

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .connecting: return "Connecting to AltServer…"
        case .authenticating: return "Signing in to Apple…"
        case .registeringDevice: return "Registering this device…"
        case .preparingCertificate: return "Preparing signing certificate…"
        case .preparingProfiles(let current, let total): return "Creating profile \(current) of \(total)…"
        }
    }

    func submitVerificationCode() {
        let value = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = verificationReply
        verificationReply = nil
        verificationCode = ""
        isRequestingVerificationCode = false
        reply?(value.isEmpty ? nil : value)
    }

    func cancelVerification() {
        let reply = verificationReply
        verificationReply = nil
        verificationCode = ""
        isRequestingVerificationCode = false
        reply?(nil)
    }

    func provision(request: ProvisioningProviderRequest,
                   appleID: String,
                   password: String,
                   deviceIdentifier: String,
                   altServer: AltServerClient,
                   anisetteServerURL: URL? = nil,
                   importedCertificateData: Data?,
                   importedCertificatePassword: String?) async throws -> AltServerProvisioningResult {
        let cleanAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAppleID.isEmpty, !password.isEmpty else {
            throw AltServerProvisioningError.missingCredentials
        }
        let cleanUDID = deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUDID.isEmpty else { throw AltServerProvisioningError.missingDeviceIdentifier }

        #if canImport(AltSign)
        defer { phase = .idle }
        phase = .connecting
        let json = try await altServer.fetchAnisetteData(httpURL: anisetteServerURL)
        guard let anisette = ALTAnisetteData(json: json) else {
            throw AltServerProvisioningError.invalidAnisetteData
        }

        phase = .authenticating
        let (account, session) = try await authenticate(appleID: cleanAppleID,
                                                        password: password,
                                                        anisetteData: anisette)
        let teams = try await fetchTeams(account: account, session: session)
        guard let team = preferredTeam(from: teams, requestedTeamID: request.teamIdentifier) else {
            throw AltServerProvisioningError.noTeam
        }

        phase = .registeringDevice
        try await registerDevice(identifier: cleanUDID, team: team, session: session)

        phase = .preparingCertificate
        let certificate = try await prepareCertificate(team: team,
                                                       session: session,
                                                       importedData: importedCertificateData,
                                                       importedPassword: importedCertificatePassword)
        guard certificate.privateKey != nil, let p12 = certificate.p12Data() else {
            throw AltServerProvisioningError.certificateCreationFailed
        }
        AltServerCertificateVault.save(p12, teamIdentifier: team.identifier)

        guard let root = request.bundles.first(where: { $0.kind == .app }) ?? request.bundles.first else {
            throw ProvisioningProviderError.noProfiles
        }
        let rootBundleID = Self.accountBundleIdentifier(root.resolvedBundleIdentifier,
                                                        teamIdentifier: team.identifier)
        let targets = request.bundles.map { bundle -> (ProvisioningProviderBundle, String) in
            let resolved = bundle.resolvedBundleIdentifier.replacingOccurrences(
                of: root.resolvedBundleIdentifier,
                with: rootBundleID
            )
            return (bundle, resolved)
        }

        var profiles: [ProvisioningProviderProfile] = []
        for (index, target) in targets.enumerated() {
            phase = .preparingProfiles(index + 1, targets.count)
            let profile = try await prepareProfile(bundle: target.0,
                                                   bundleIdentifier: target.1,
                                                   team: team,
                                                   session: session)
            let leaf = target.1.split(separator: ".").last.map(String.init) ?? "app"
            profiles.append(ProvisioningProviderProfile(
                filename: "ForgeSign-\(leaf)-\(profile.uuid.uuidString).mobileprovision",
                dataBase64: profile.data.base64EncodedString()
            ))
        }

        return AltServerProvisioningResult(certificateData: p12,
                                           certificatePassword: "",
                                           profiles: profiles,
                                           rootBundleIdentifier: rootBundleID,
                                           teamIdentifier: team.identifier)
        #else
        throw AltServerProvisioningError.unavailable
        #endif
    }
}

#if canImport(AltSign)
private extension AltServerProvisioningService {
    func authenticate(appleID: String,
                      password: String,
                      anisetteData: ALTAnisetteData) async throws -> (ALTAccount, ALTAppleAPISession) {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData,
                verificationHandler: { [weak self] reply in
                    Task { @MainActor in
                        guard let self else {
                            reply(nil)
                            return
                        }
                        self.verificationReply = reply
                        self.isRequestingVerificationCode = true
                    }
                },
                completionHandler: { account, session, error in
                    if let account, let session {
                        continuation.resume(returning: (account, session))
                    } else {
                        continuation.resume(throwing: AltServerProvisioningError.authenticationFailed(
                            error?.localizedDescription ?? "Apple returned no session."
                        ))
                    }
                }
            )
        }
    }

    func fetchTeams(account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                if let teams {
                    continuation.resume(returning: teams)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.authenticationFailed(
                        error?.localizedDescription ?? "Apple returned no teams."
                    ))
                }
            }
        }
    }

    func preferredTeam(from teams: [ALTTeam], requestedTeamID: String?) -> ALTTeam? {
        if let requestedTeamID,
           let exact = teams.first(where: { $0.identifier.caseInsensitiveCompare(requestedTeamID) == .orderedSame }) {
            return exact
        }
        return teams.first(where: { $0.type == .individual })
            ?? teams.first(where: { $0.type == .free })
            ?? teams.first
    }

    func registerDevice(identifier: String,
                        team: ALTTeam,
                        session: ALTAppleAPISession) async throws {
        let devices: [ALTDevice] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchDevices(for: team, types: [.iphone, .ipad], session: session) { devices, error in
                if let devices {
                    continuation.resume(returning: devices)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.deviceRegistrationFailed(
                        error?.localizedDescription ?? "Apple returned no devices."
                    ))
                }
            }
        }
        guard !devices.contains(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            return
        }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ALTDevice, Error>) in
            ALTAppleAPI.shared.registerDevice(name: UIDevice.current.name,
                                              identifier: identifier,
                                              type: .iphone,
                                              team: team,
                                              session: session) { device, error in
                if let device {
                    continuation.resume(returning: device)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.deviceRegistrationFailed(
                        error?.localizedDescription ?? "Apple rejected the device."
                    ))
                }
            }
        }
    }

    func prepareCertificate(team: ALTTeam,
                            session: ALTAppleAPISession,
                            importedData: Data?,
                            importedPassword: String?) async throws -> ALTCertificate {
        let certificates: [ALTCertificate] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { certificates, error in
                if let certificates {
                    continuation.resume(returning: certificates)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.authenticationFailed(
                        error?.localizedDescription ?? "Apple returned no certificates."
                    ))
                }
            }
        }

        let candidateData = [importedData, AltServerCertificateVault.load(teamIdentifier: team.identifier)]
            .compactMap { $0 }
        for data in candidateData {
            let candidate = ALTCertificate(p12Data: data, password: importedPassword ?? "")
                ?? ALTCertificate(p12Data: data, password: "")
            if let candidate,
               certificates.contains(where: { $0.serialNumber == candidate.serialNumber }),
               candidate.privateKey != nil {
                return candidate
            }
        }

        guard certificates.isEmpty else {
            throw AltServerProvisioningError.certificateConflict
        }
        let created: ALTCertificate = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.addCertificate(machineName: "ForgeSign - \(UIDevice.current.name)",
                                              to: team,
                                              session: session) { certificate, error in
                if let certificate {
                    continuation.resume(returning: certificate)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.authenticationFailed(
                        error?.localizedDescription ?? "Apple rejected the certificate request."
                    ))
                }
            }
        }
        guard let privateKey = created.privateKey else {
            throw AltServerProvisioningError.certificateCreationFailed
        }
        let refreshed: [ALTCertificate] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { certificates, error in
                if let certificates {
                    continuation.resume(returning: certificates)
                } else {
                    continuation.resume(throwing: error ?? AltServerProvisioningError.certificateCreationFailed)
                }
            }
        }
        guard let certificate = refreshed.first(where: { $0.serialNumber == created.serialNumber }) else {
            throw AltServerProvisioningError.certificateCreationFailed
        }
        certificate.privateKey = privateKey
        return certificate
    }

    func prepareProfile(bundle: ProvisioningProviderBundle,
                        bundleIdentifier: String,
                        team: ALTTeam,
                        session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        let appID = try await prepareAppID(bundle: bundle,
                                          bundleIdentifier: bundleIdentifier,
                                          team: team,
                                          session: session)
        if !bundle.requiredAppGroups.isEmpty {
            try await assignAppGroups(bundle.requiredAppGroups, to: appID, team: team, session: session)
        }
        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchProvisioningProfile(for: appID,
                                                        deviceType: .iphone,
                                                        team: team,
                                                        session: session) { profile, error in
                if let profile {
                    continuation.resume(returning: profile)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.profileFailed(
                        bundleIdentifier,
                        error?.localizedDescription ?? "Apple returned no profile."
                    ))
                }
            }
        }
    }

    func prepareAppID(bundle: ProvisioningProviderBundle,
                      bundleIdentifier: String,
                      team: ALTTeam,
                      session: ALTAppleAPISession) async throws -> ALTAppID {
        let appIDs: [ALTAppID] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) { appIDs, error in
                if let appIDs {
                    continuation.resume(returning: appIDs)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.appIDFailed(
                        bundleIdentifier,
                        error?.localizedDescription ?? "Apple returned no App IDs."
                    ))
                }
            }
        }
        let appID: ALTAppID
        if let existing = appIDs.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            appID = existing
        } else {
            appID = try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.shared.addAppID(withName: Self.appIDName(for: bundle),
                                           bundleIdentifier: bundleIdentifier,
                                           team: team,
                                           session: session) { appID, error in
                    if let appID {
                        continuation.resume(returning: appID)
                    } else {
                        continuation.resume(throwing: AltServerProvisioningError.appIDFailed(
                            bundleIdentifier,
                            error?.localizedDescription ?? "Apple rejected the App ID."
                        ))
                    }
                }
            }
        }

        let needsGroups = !bundle.requiredAppGroups.isEmpty
        let hasGroups = (appID.features[.appGroups] as? Bool) == true
        guard needsGroups != hasGroups else { return appID }
        let updated = appID.copy() as! ALTAppID
        var features = updated.features
        features[.appGroups] = needsGroups
        updated.features = features
        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.update(updated, team: team, session: session) { appID, error in
                if let appID {
                    continuation.resume(returning: appID)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.appIDFailed(
                        bundleIdentifier,
                        error?.localizedDescription ?? "Apple rejected the App ID capabilities."
                    ))
                }
            }
        }
    }

    func assignAppGroups(_ requestedGroups: [String],
                         to appID: ALTAppID,
                         team: ALTTeam,
                         session: ALTAppleAPISession) async throws {
        let fetched: [ALTAppGroup] = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchAppGroups(for: team, session: session) { groups, error in
                if let groups {
                    continuation.resume(returning: groups)
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.appGroupFailed(
                        requestedGroups.first ?? "unknown",
                        error?.localizedDescription ?? "Apple returned no App Groups."
                    ))
                }
            }
        }
        var groups: [ALTAppGroup] = []
        for requested in requestedGroups {
            let resolved = Self.accountAppGroupIdentifier(requested, teamIdentifier: team.identifier)
            if let existing = fetched.first(where: { $0.groupIdentifier == resolved }) {
                groups.append(existing)
                continue
            }
            let created: ALTAppGroup = try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.shared.addAppGroup(withName: "ForgeSign " + requested.replacingOccurrences(of: ".", with: " "),
                                               groupIdentifier: resolved,
                                               team: team,
                                               session: session) { group, error in
                    if let group {
                        continuation.resume(returning: group)
                    } else {
                        continuation.resume(throwing: AltServerProvisioningError.appGroupFailed(
                            resolved,
                            error?.localizedDescription ?? "Apple rejected the App Group."
                        ))
                    }
                }
            }
            groups.append(created)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ALTAppleAPI.shared.assign(appID, to: groups, team: team, session: session) { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.appGroupFailed(
                        groups.first?.groupIdentifier ?? "unknown",
                        error?.localizedDescription ?? "Apple rejected the App Group assignment."
                    ))
                }
            }
        }
    }

    static func accountBundleIdentifier(_ bundleID: String, teamIdentifier: String) -> String {
        let suffix = "." + teamIdentifier
        return bundleID.hasSuffix(suffix) ? bundleID : bundleID + suffix
    }

    static func accountAppGroupIdentifier(_ groupID: String, teamIdentifier: String) -> String {
        let suffix = "." + teamIdentifier
        return groupID.hasSuffix(suffix) ? groupID : groupID + suffix
    }

    static func appIDName(for bundle: ProvisioningProviderBundle) -> String {
        let leaf = bundle.resolvedBundleIdentifier.split(separator: ".").last.map(String.init) ?? "App"
        return "ForgeSign \(bundle.kind.displayName) \(leaf)"
    }
}
#endif

private enum AltServerCertificateVault {
    private static let service = "com.forgesign.mobile.altserver-certificate"

    static func save(_ data: Data, teamIdentifier: String) {
        delete(teamIdentifier: teamIdentifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamIdentifier,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(teamIdentifier: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamIdentifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func delete(teamIdentifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamIdentifier
        ]
        SecItemDelete(query as CFDictionary)
    }
}
