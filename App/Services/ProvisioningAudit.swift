import Foundation

enum ProvisioningCheckState: Equatable, Sendable {
    case ready
    case warning
    case removed
    case missingProfile
    case wrongTeam
    case wrongCertificate
    case expired
    case deviceMismatch
    case missingAppGroups

    var isBlocking: Bool {
        switch self {
        case .ready, .warning, .removed: return false
        default: return true
        }
    }
}

struct ProvisioningAuditRow: Equatable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let kind: SignableBundleInspection.Kind
    let originalBundleID: String
    let resolvedBundleID: String
    let state: ProvisioningCheckState
    let detail: String
    let profileID: UUID?
    let profileName: String?
    let requiredAppGroups: [String]
    let resolvedAppGroups: [String]
}

struct ProvisioningAudit: Equatable, Sendable {
    let rows: [ProvisioningAuditRow]
    let selectedProfileIDs: [UUID]

    var isReady: Bool { !rows.contains { $0.state.isBlocking } }

    var firstBlockingMessage: String? {
        firstBlockingMessage(includeNested: true)
    }

    func firstBlockingMessage(includeNested: Bool) -> String? {
        guard let row = rows.first(where: {
            $0.state.isBlocking && (includeNested || $0.kind == .app)
        }) else { return nil }
        return "\(row.kind.displayName) \(row.resolvedBundleID): \(row.detail)"
    }
}

enum ProvisioningAuditService {
    static func makeAudit(inspection: IPAPreflight,
                          profiles: [ProfileRecord],
                          preferredProfileID: UUID?,
                          certificate: CertificateRecord?,
                          requestedBundleID: String,
                          removeExtensions: Bool,
                          deviceIdentifier: String? = currentDeviceIdentifier,
                          strictNestedBundles: Bool = true,
                          now: Date = .now) -> ProvisioningAudit {
        let trimmedBundleID = requestedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootOriginalID = inspection.bundleIdentifier
        let rootResolvedID = trimmedBundleID.isEmpty ? rootOriginalID : trimmedBundleID

        var rows = inspection.bundles.map { bundle -> ProvisioningAuditRow in
            let resolvedID = resolvedBundleID(for: bundle.bundleIdentifier,
                                              rootOriginalID: rootOriginalID,
                                              rootResolvedID: rootResolvedID)
            if removeExtensions && bundle.kind == .extension {
                return ProvisioningAuditRow(path: bundle.path, kind: bundle.kind,
                                            originalBundleID: bundle.bundleIdentifier,
                                            resolvedBundleID: resolvedID,
                                            state: .removed,
                                            detail: "This bundle will be removed before signing.",
                                            profileID: nil, profileName: nil,
                                            requiredAppGroups: bundle.requiredAppGroups,
                                            resolvedAppGroups: [])
            }

            let result = match(bundle: bundle,
                               resolvedBundleID: resolvedID,
                               profiles: profiles,
                               preferredProfileID: bundle.kind == .app ? preferredProfileID : nil,
                               certificate: certificate,
                               deviceIdentifier: deviceIdentifier,
                               now: now)
            if !strictNestedBundles && bundle.kind != .app &&
                (result.state == .missingProfile || result.state == .missingAppGroups) {
                return ProvisioningAuditRow(
                    path: result.path, kind: result.kind,
                    originalBundleID: result.originalBundleID,
                    resolvedBundleID: result.resolvedBundleID,
                    state: .warning,
                    detail: result.state == .missingAppGroups
                        ? "No matching App Groups were found; the app profile will be used."
                        : "No matching profile; the app profile will be used for this bundle.",
                    profileID: result.profileID, profileName: result.profileName,
                    requiredAppGroups: result.requiredAppGroups,
                    resolvedAppGroups: result.resolvedAppGroups
                )
            }
            return result
        }

        enforceSharedAppGroups(in: &rows)

        // The native signer historically treats the first asset as the root
        // fallback. Keep the root profile first, then stable bundle order.
        let usableIDs = rows.compactMap { row in
            row.state.isBlocking ? nil : row.profileID
        }
        let orderedIDs = usableIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        return ProvisioningAudit(rows: rows, selectedProfileIDs: orderedIDs)
    }

    static var currentDeviceIdentifier: String? {
        let keys = ["ALTDeviceID", "ALTDeviceIdentifier"]
        for key in keys {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func match(bundle: SignableBundleInspection,
                              resolvedBundleID: String,
                              profiles: [ProfileRecord],
                              preferredProfileID: UUID?,
                              certificate: CertificateRecord?,
                              deviceIdentifier: String?,
                              now: Date) -> ProvisioningAuditRow {
        let matching = profiles
            .filter { profileMatchesBundleID($0, bundleID: resolvedBundleID) }
            .sorted { lhs, rhs in
                let left = matchRank(lhs, bundleID: resolvedBundleID,
                                     preferredProfileID: preferredProfileID)
                let right = matchRank(rhs, bundleID: resolvedBundleID,
                                      preferredProfileID: preferredProfileID)
                if left != right { return left > right }
                return lhs.addedAt < rhs.addedAt
            }

        guard !matching.isEmpty else {
            return row(bundle: bundle, resolvedBundleID: resolvedBundleID,
                       state: .missingProfile,
                       detail: "No imported provisioning profile matches this bundle ID.")
        }

        var bestFailure: ProvisioningAuditRow?
        for profile in matching {
            let evaluation = evaluate(profile: profile, bundle: bundle,
                                      resolvedBundleID: resolvedBundleID,
                                      certificate: certificate,
                                      deviceIdentifier: deviceIdentifier,
                                      now: now)
            if !evaluation.state.isBlocking { return evaluation }
            if bestFailure == nil { bestFailure = evaluation }
        }
        return bestFailure ?? row(bundle: bundle, resolvedBundleID: resolvedBundleID,
                                  state: .missingProfile,
                                  detail: "No usable provisioning profile was found.")
    }

    private static func evaluate(profile: ProfileRecord,
                                 bundle: SignableBundleInspection,
                                 resolvedBundleID: String,
                                 certificate: CertificateRecord?,
                                 deviceIdentifier: String?,
                                 now: Date) -> ProvisioningAuditRow {
        let makeRow: (ProvisioningCheckState, String) -> ProvisioningAuditRow = { state, detail in
            row(bundle: bundle, resolvedBundleID: resolvedBundleID,
                state: state, detail: detail, profile: profile)
        }

        guard profile.profileIsAuthentic else {
            return makeRow(.missingProfile, "The matching profile failed authenticity validation.")
        }
        if let expiry = profile.notAfter, expiry <= now {
            return makeRow(.expired, "Profile “\(profile.displayName)” is expired.")
        }
        if let certificateTeam = certificate?.teamID,
           let profileTeam = profile.teamID,
           certificateTeam.caseInsensitiveCompare(profileTeam) != .orderedSame {
            return makeRow(.wrongTeam,
                           "Profile team \(profileTeam) does not match certificate team \(certificateTeam).")
        }
        if let fingerprint = certificate?.certificateSHA256,
           !profile.developerCertificateSHA256.isEmpty,
           !profile.developerCertificateSHA256.contains(where: {
               $0.caseInsensitiveCompare(fingerprint) == .orderedSame
           }) {
            return makeRow(.wrongCertificate,
                           "The selected signing certificate is not included in profile “\(profile.displayName)”.")
        }
        if let deviceIdentifier,
           profile.provisionsAllDevices != true,
           !profile.provisionedDevices.isEmpty,
           !profile.provisionedDevices.contains(where: {
               $0.caseInsensitiveCompare(deviceIdentifier) == .orderedSame
           }) {
            return makeRow(.deviceMismatch,
                           "This device is not included in profile “\(profile.displayName)”.")
        }
        if !bundle.requiredAppGroups.isEmpty && profile.appGroups.isEmpty {
            return makeRow(.missingAppGroups,
                           "The matching profile does not grant the App Groups required by this bundle.")
        }

        let coverageUnknown = deviceIdentifier == nil &&
            profile.provisionsAllDevices != true && !profile.provisionedDevices.isEmpty
        let entitlementUnknown = !bundle.entitlementsAvailable
        if coverageUnknown || entitlementUnknown {
            var warnings: [String] = []
            if coverageUnknown { warnings.append("device membership cannot be confirmed on-device") }
            if entitlementUnknown { warnings.append("original entitlement metadata is unavailable") }
            return makeRow(.warning,
                           "Profile “\(profile.displayName)” matches; \(warnings.joined(separator: "; ")).")
        }
        return makeRow(.ready, "Profile “\(profile.displayName)” matches.")
    }

    private static func enforceSharedAppGroups(in rows: inout [ProvisioningAuditRow]) {
        let consumers = rows.indices.filter {
            !rows[$0].state.isBlocking && !rows[$0].requiredAppGroups.isEmpty &&
                !rows[$0].resolvedAppGroups.isEmpty
        }
        guard consumers.count > 1 else { return }
        let shared = consumers.dropFirst().reduce(Set(rows[consumers[0]].resolvedAppGroups)) {
            $0.intersection(rows[$1].resolvedAppGroups)
        }
        guard shared.isEmpty else { return }
        for index in consumers {
            let current = rows[index]
            rows[index] = ProvisioningAuditRow(
                path: current.path, kind: current.kind,
                originalBundleID: current.originalBundleID,
                resolvedBundleID: current.resolvedBundleID,
                state: .missingAppGroups,
                detail: "Its profile does not share an App Group with the other provisioned bundles.",
                profileID: current.profileID, profileName: current.profileName,
                requiredAppGroups: current.requiredAppGroups,
                resolvedAppGroups: current.resolvedAppGroups
            )
        }
    }

    private static func row(bundle: SignableBundleInspection,
                            resolvedBundleID: String,
                            state: ProvisioningCheckState,
                            detail: String,
                            profile: ProfileRecord? = nil) -> ProvisioningAuditRow {
        ProvisioningAuditRow(path: bundle.path, kind: bundle.kind,
                             originalBundleID: bundle.bundleIdentifier,
                             resolvedBundleID: resolvedBundleID,
                             state: state, detail: detail,
                             profileID: profile?.id, profileName: profile?.displayName,
                             requiredAppGroups: bundle.requiredAppGroups,
                             resolvedAppGroups: profile?.appGroups ?? [])
    }

    private static func resolvedBundleID(for original: String,
                                         rootOriginalID: String,
                                         rootResolvedID: String) -> String {
        guard rootOriginalID != rootResolvedID else { return original }
        return original.replacingOccurrences(of: rootOriginalID, with: rootResolvedID)
    }

    private static func profileMatchesBundleID(_ profile: ProfileRecord, bundleID: String) -> Bool {
        guard let applicationIdentifier = profile.applicationIdentifier,
              let separator = applicationIdentifier.firstIndex(of: ".") else { return false }
        let pattern = String(applicationIdentifier[applicationIdentifier.index(after: separator)...])
        return wildcardMatch(pattern: pattern, value: bundleID)
    }

    private static func matchRank(_ profile: ProfileRecord,
                                  bundleID: String,
                                  preferredProfileID: UUID?) -> Int {
        guard let applicationIdentifier = profile.applicationIdentifier,
              let separator = applicationIdentifier.firstIndex(of: ".") else { return 0 }
        let pattern = String(applicationIdentifier[applicationIdentifier.index(after: separator)...])
        let exact = pattern == bundleID ? 1_000_000 : 0
        let preferred = profile.id == preferredProfileID ? 100_000 : 0
        return exact + preferred + pattern.filter { $0 != "*" }.count
    }

    private static func wildcardMatch(pattern: String, value: String) -> Bool {
        if pattern == "*" || pattern == value { return true }
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var searchStart = value.startIndex
        for (index, piece) in pieces.enumerated() where !piece.isEmpty {
            if index == 0 && !pattern.hasPrefix("*") {
                guard value[searchStart...].hasPrefix(piece) else { return false }
                searchStart = value.index(searchStart, offsetBy: piece.count)
                continue
            }
            guard let range = value.range(of: piece, range: searchStart..<value.endIndex) else { return false }
            searchStart = range.upperBound
        }
        if let last = pieces.last, !last.isEmpty, !pattern.hasSuffix("*") {
            return value.hasSuffix(last)
        }
        return true
    }
}
