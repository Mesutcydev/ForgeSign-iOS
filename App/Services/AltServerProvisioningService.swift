import Foundation
import Security
import UIKit

#if FORGE_BRIDGE && canImport(AltSign)
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
    case appleServiceUnavailable(String)
    case noTeam
    case requestedTeamUnavailable(String)
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
            return "The selected anisette source returned data that AltSign could not use."
        case .authenticationFailed(let detail):
            return "Apple Account sign-in failed: \(detail)"
        case .appleServiceUnavailable(let detail):
            // Keep Apple's own words: a blanket "HTTP 503" hid anisette and
            // parse failures that need a different fix than "retry later".
            return "Apple Account sign-in could not finish because Apple returned an invalid response (\(detail)). Retry later or pick another anisette source; this is not a provisioning-profile mismatch."
        case .noTeam:
            return "This Apple Account has no development team."
        case .requestedTeamUnavailable(let identifier):
            return "Team \(identifier) is not available to this Apple Account. Choose a profile from an available team or use another account."
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
        case .connecting: return "Getting Apple sign-in data…"
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
                   anisettePlan: AnisettePreference.Plan = AnisettePreference.plan(mode: .automatic, remoteServerAddress: nil, customURLText: ""),
                   importedCertificateData: Data?,
                   importedCertificatePassword: String?) async throws -> AltServerProvisioningResult {
        let cleanAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAppleID.isEmpty, !password.isEmpty else {
            throw AltServerProvisioningError.missingCredentials
        }
        let cleanUDID = deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUDID.isEmpty else { throw AltServerProvisioningError.missingDeviceIdentifier }

        #if FORGE_BRIDGE && canImport(AltSign)
        defer { phase = .idle }
        phase = .connecting
        let json = try await altServer.fetchAnisetteData(plan: anisettePlan)
        guard let anisette = ALTAnisetteData(json: json) else {
            throw AltServerProvisioningError.invalidAnisetteData
        }

        phase = .authenticating
        let (account, session) = try await authenticate(appleID: cleanAppleID,
                                                        password: password,
                                                        anisetteData: anisette)
        let teams = try await fetchTeams(account: account, session: session)
        if let requestedTeamID = request.teamIdentifier,
           !teams.contains(where: { $0.identifier.caseInsensitiveCompare(requestedTeamID) == .orderedSame }) {
            throw AltServerProvisioningError.requestedTeamUnavailable(requestedTeamID)
        }
        guard let team = preferredTeam(from: teams, requestedTeamID: request.teamIdentifier) else {
            throw AltServerProvisioningError.noTeam
        }
        let deviceType: ALTDeviceType = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone

        phase = .registeringDevice
        try await registerDevice(identifier: cleanUDID,
                                 deviceName: UIDevice.current.name,
                                 deviceType: deviceType,
                                 team: team,
                                 session: session)

        phase = .preparingCertificate
        let certificate = try await prepareCertificate(team: team,
                                                       session: session,
                                                       deviceName: UIDevice.current.name,
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
            let resolved = BundleIdentifierResolver.replacingRootPrefix(
                in: bundle.resolvedBundleIdentifier,
                originalRoot: root.resolvedBundleIdentifier,
                resolvedRoot: rootBundleID
            )
            return (bundle, resolved)
        }

        var profiles: [ProvisioningProviderProfile] = []
        for (index, target) in targets.enumerated() {
            phase = .preparingProfiles(index + 1, targets.count)
            let profile = try await prepareProfile(bundle: target.0,
                                                   bundleIdentifier: target.1,
                                                   deviceType: deviceType,
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

#if FORGE_BRIDGE && canImport(AltSign)
private extension AltServerProvisioningService {
    nonisolated func authenticate(appleID: String,
                                  password: String,
                                  anisetteData: ALTAnisetteData) async throws -> (ALTAccount, ALTAppleAPISession) {
        do {
            return try await authenticateOnce(appleID: appleID,
                                              password: password,
                                              anisetteData: anisetteData)
        } catch {
            // The patched AltSign dependency retries GSA 5xx responses five
            // times, using a fresh URLSession for every attempt. Retrying the
            // whole exchange here would duplicate that work and can outlive
            // the short anisette validity window.
            if Self.isRetryableAppleResponse(error) {
                throw AltServerProvisioningError.appleServiceUnavailable(Self.underlyingDetail(error))
            }
            throw error
        }
    }

    nonisolated private func authenticateOnce(appleID: String,
                                              password: String,
                                              anisetteData: ALTAnisetteData) async throws -> (ALTAccount, ALTAppleAPISession) {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.authenticate(
                appleID: appleID,
                password: password,
                anisetteData: anisetteData,
                verificationHandler: { [weak self] reply in
                    let replyBox = VerificationReplyBox(reply)
                    Task { @MainActor [weak self, replyBox] in
                        guard let self else {
                            replyBox.call(nil)
                            return
                        }
                        self.verificationReply = { code in replyBox.call(code) }
                        self.isRequestingVerificationCode = true
                    }
                },
                completionHandler: { account, session, error in
                    // AltSign completes on its URLSession delegate queue. This
                    // callback is deliberately nonisolated; CheckedContinuation
                    // is thread-safe and must be resumed directly from the
                    // queue that invokes the Objective-C callback. Hopping the
                    // callback itself to MainActor triggers Swift's isolation
                    // precondition on iOS 27 before the task can start.
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

    /// `authenticateOnce` wraps AltSign's error as `authenticationFailed`;
    /// unwrap it so the message names what Apple actually sent.
    nonisolated private static func underlyingDetail(_ error: Error) -> String {
        if case AltServerProvisioningError.authenticationFailed(let detail) = error { return detail }
        return error.localizedDescription
    }

    nonisolated private static func isRetryableAppleResponse(_ error: Error) -> Bool {
        let nsError = error as NSError
        let debugDescription = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
        let text = "\(nsError.localizedDescription) \(debugDescription)"
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == 3840)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse)
            || text.localizedCaseInsensitiveContains("correct format")
            || text.localizedCaseInsensitiveContains("unknown tag html")
            || text.range(of: #"\bHTTP\s+5\d\d\b"#, options: .regularExpression) != nil
            || text.localizedCaseInsensitiveContains("service temporarily unavailable")
    }

    nonisolated func fetchTeams(account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
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

    nonisolated func registerDevice(identifier: String,
                                    deviceName: String,
                                    deviceType: ALTDeviceType,
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
            ALTAppleAPI.shared.registerDevice(name: deviceName,
                                              identifier: identifier,
                                              type: deviceType,
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

    nonisolated func prepareCertificate(team: ALTTeam,
                                        session: ALTAppleAPISession,
                                        deviceName: String,
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
            ALTAppleAPI.shared.addCertificate(machineName: "ForgeSign - \(deviceName)",
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

    nonisolated func prepareProfile(bundle: ProvisioningProviderBundle,
                                    bundleIdentifier: String,
                                    deviceType: ALTDeviceType,
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
                                                        deviceType: deviceType,
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

    nonisolated func prepareAppID(bundle: ProvisioningProviderBundle,
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
        // Existing App IDs can be shared with other installs. A bundle that
        // does not need groups must not disable a capability already enabled
        // for that App ID.
        guard needsGroups && !hasGroups else { return appID }
        guard let updated = appID.copy() as? ALTAppID else {
            throw AltServerProvisioningError.appIDFailed(
                bundleIdentifier,
                "Apple returned an invalid App ID object while updating capabilities."
            )
        }
        var features = updated.features
        features[.appGroups] = true
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

    nonisolated func assignAppGroups(_ requestedGroups: [String],
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
        let groupsToAssign = groups
        let firstGroupIdentifier = groupsToAssign.first?.groupIdentifier ?? "unknown"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ALTAppleAPI.shared.assign(appID, to: groupsToAssign, team: team, session: session) { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: AltServerProvisioningError.appGroupFailed(
                        firstGroupIdentifier,
                        error?.localizedDescription ?? "Apple rejected the App Group assignment."
                    ))
                }
            }
        }
    }

    nonisolated static func accountBundleIdentifier(_ bundleID: String, teamIdentifier: String) -> String {
        let suffix = "." + teamIdentifier
        return bundleID.hasSuffix(suffix) ? bundleID : bundleID + suffix
    }

    nonisolated static func accountAppGroupIdentifier(_ groupID: String, teamIdentifier: String) -> String {
        let suffix = "." + teamIdentifier
        return groupID.hasSuffix(suffix) ? groupID : groupID + suffix
    }

    nonisolated static func appIDName(for bundle: ProvisioningProviderBundle) -> String {
        let leaf = bundle.resolvedBundleIdentifier.split(separator: ".").last.map(String.init) ?? "App"
        return "ForgeSign \(bundle.kind.displayName) \(leaf)"
    }
}

private final class VerificationReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((String?) -> Void)?

    init(_ reply: @escaping (String?) -> Void) {
        self.reply = reply
    }

    func call(_ code: String?) {
        lock.lock()
        let reply = self.reply
        self.reply = nil
        lock.unlock()
        reply?(code)
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
