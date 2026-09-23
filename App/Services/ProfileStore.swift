import Foundation
import CryptoKit

struct ProfileRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let name: String?
    let teamID: String?
    let applicationIdentifier: String?
    let notAfter: Date?
    let provisionedDeviceCount: Int?
    let provisionsAllDevices: Bool?
    let getTaskAllow: Bool?
    let profileUUID: String?
    let provisionedDevices: [String]
    let appGroups: [String]
    let keychainAccessGroups: [String]
    let developerCertificateSHA256: [String]
    let profileIsAuthentic: Bool
    let addedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, filename, name, teamID, applicationIdentifier, notAfter
        case provisionedDeviceCount, provisionsAllDevices, getTaskAllow
        case profileUUID, provisionedDevices, appGroups, keychainAccessGroups
        case developerCertificateSHA256
        case profileIsAuthentic, addedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        filename = try values.decode(String.self, forKey: .filename)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        teamID = try values.decodeIfPresent(String.self, forKey: .teamID)
        applicationIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationIdentifier)
        notAfter = try values.decodeIfPresent(Date.self, forKey: .notAfter)
        provisionedDeviceCount = try values.decodeIfPresent(Int.self, forKey: .provisionedDeviceCount)
        provisionsAllDevices = try values.decodeIfPresent(Bool.self, forKey: .provisionsAllDevices)
        getTaskAllow = try values.decodeIfPresent(Bool.self, forKey: .getTaskAllow)
        profileUUID = try values.decodeIfPresent(String.self, forKey: .profileUUID)
        provisionedDevices = try values.decodeIfPresent([String].self, forKey: .provisionedDevices) ?? []
        appGroups = try values.decodeIfPresent([String].self, forKey: .appGroups) ?? []
        keychainAccessGroups = try values.decodeIfPresent([String].self, forKey: .keychainAccessGroups) ?? []
        developerCertificateSHA256 = try values.decodeIfPresent([String].self, forKey: .developerCertificateSHA256) ?? []
        profileIsAuthentic = try values.decodeIfPresent(Bool.self, forKey: .profileIsAuthentic) ?? false
        addedAt = try values.decode(Date.self, forKey: .addedAt)
    }

    init(id: UUID, filename: String, name: String?, teamID: String?, applicationIdentifier: String?,
         notAfter: Date?, provisionedDeviceCount: Int?, provisionsAllDevices: Bool?, getTaskAllow: Bool?,
         profileUUID: String? = nil, provisionedDevices: [String] = [], appGroups: [String] = [],
         keychainAccessGroups: [String] = [], developerCertificateSHA256: [String] = [],
         profileIsAuthentic: Bool = false, addedAt: Date) {
        self.id = id
        self.filename = filename
        self.name = name
        self.teamID = teamID
        self.applicationIdentifier = applicationIdentifier
        self.notAfter = notAfter
        self.provisionedDeviceCount = provisionedDeviceCount
        self.provisionsAllDevices = provisionsAllDevices
        self.getTaskAllow = getTaskAllow
        self.profileUUID = profileUUID
        self.provisionedDevices = provisionedDevices
        self.appGroups = appGroups
        self.keychainAccessGroups = keychainAccessGroups
        self.developerCertificateSHA256 = developerCertificateSHA256
        self.profileIsAuthentic = profileIsAuthentic
        self.addedAt = addedAt
    }

    var displayName: String { name ?? filename }

    func withAuthenticity(_ value: Bool) -> ProfileRecord {
        ProfileRecord(id: id, filename: filename, name: name, teamID: teamID,
                      applicationIdentifier: applicationIdentifier, notAfter: notAfter,
                      provisionedDeviceCount: provisionedDeviceCount,
                      provisionsAllDevices: provisionsAllDevices, getTaskAllow: getTaskAllow,
                      profileUUID: profileUUID, provisionedDevices: provisionedDevices,
                      appGroups: appGroups, keychainAccessGroups: keychainAccessGroups,
                      developerCertificateSHA256: developerCertificateSHA256,
                      profileIsAuthentic: value, addedAt: addedAt)
    }

    func refreshed(with info: ProvisioningProfileMetadata, authenticity: Bool) -> ProfileRecord {
        // A plist parser can still recover a valid profile while omitting an
        // optional field (notably application-identifier on some profiles).
        // Never replace known-good cached metadata with that omission during
        // the background refresh.
        let refreshedName = info.name == "Provisioning Profile" ? (name ?? info.name) : info.name
        let refreshedDevices = info.provisionedDevices.isEmpty ? provisionedDevices : info.provisionedDevices
        let refreshedAppGroups = info.appGroups.isEmpty ? appGroups : info.appGroups
        let refreshedKeychainGroups = info.keychainAccessGroups.isEmpty ? keychainAccessGroups : info.keychainAccessGroups
        let refreshedCertificates = info.developerCertificateSHA256.isEmpty
            ? developerCertificateSHA256 : info.developerCertificateSHA256
        return ProfileRecord(id: id, filename: filename, name: refreshedName,
                             teamID: info.teamID ?? teamID,
                             applicationIdentifier: info.applicationIdentifier ?? applicationIdentifier,
                             notAfter: info.expirationDate ?? notAfter,
                             provisionedDeviceCount: info.provisionedDevices.isEmpty
                               ? provisionedDeviceCount : info.provisionedDevices.count,
                             provisionsAllDevices: info.provisionsAllDevices ?? provisionsAllDevices,
                             getTaskAllow: info.getTaskAllow ?? getTaskAllow,
                             profileUUID: info.uuid ?? profileUUID,
                             provisionedDevices: refreshedDevices,
                             appGroups: refreshedAppGroups,
                             keychainAccessGroups: refreshedKeychainGroups,
                             developerCertificateSHA256: refreshedCertificates,
                             profileIsAuthentic: authenticity, addedAt: addedAt)
    }
}

/// Remembers imported provisioning profiles (.mobileprovision) on-device
/// (Application Support) so they survive app restarts, exactly like the
/// certificate store.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ProfileRecord] = []
    @Published private(set) var isRefreshingMetadata = false
    @Published var selectedID: UUID?

    private let dir: URL
    private let indexURL: URL
    private var refreshTask: Task<Void, Never>?

    private struct RefreshResult: Sendable {
        let id: UUID
        let record: ProfileRecord?
    }

    private struct Index: Codable {
        var profiles: [ProfileRecord] = []
        var selectedID: UUID?
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("profiles.json")
        load()
        refreshMetadataInBackground()
    }

    var selected: ProfileRecord? {
        profiles.first { $0.id == selectedID }
    }

    func fileURL(for record: ProfileRecord) -> URL {
        dir.appendingPathComponent(record.filename)
    }

    enum ImportError: LocalizedError {
        case unreadable
        case notAProfile
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .notAProfile: return "Not a valid .mobileprovision file."
            case .copyFailed: return "The profile could not be saved."
            }
        }
    }

    /// Copies a picked provisioning profile into the app container and selects it.
    @discardableResult
    func importProfile(from source: URL) -> Result<ProfileRecord, ImportError> {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else { return .failure(.unreadable) }
        guard let info = ProvisioningProfileInspector.inspect(data: data) else {
            return .failure(.notAProfile)
        }
        guard ProfileAuthenticityChecker.isAuthentic(source) else {
            return .failure(.notAProfile)
        }

        var filename = source.lastPathComponent
        if profiles.contains(where: { $0.filename == filename }) {
            let stem = source.deletingPathExtension().lastPathComponent
            let short = UUID().uuidString.prefix(6)
            filename = "\(stem)-\(short).\(source.pathExtension)"
        }

        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .completeFileProtection)
        } catch {
            return .failure(.copyFailed)
        }

        let record = ProfileRecord(
            id: UUID(),
            filename: filename,
            name: info.name,
            teamID: info.teamID,
            applicationIdentifier: info.applicationIdentifier,
            notAfter: info.expirationDate,
            provisionedDeviceCount: info.provisionedDevices.isEmpty ? nil : info.provisionedDevices.count,
            provisionsAllDevices: info.provisionsAllDevices,
            getTaskAllow: info.getTaskAllow,
            profileUUID: info.uuid,
            provisionedDevices: info.provisionedDevices,
            appGroups: info.appGroups,
            keychainAccessGroups: info.keychainAccessGroups,
            developerCertificateSHA256: info.developerCertificateSHA256,
            profileIsAuthentic: true,
            addedAt: .now
        )

        profiles.append(record)
        selectedID = record.id
        save()
        return .success(record)
    }

    @discardableResult
    func importProfile(data: Data, suggestedFilename: String) -> Result<ProfileRecord, ImportError> {
        let safeName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let filename = safeName.lowercased().hasSuffix(".mobileprovision")
            ? safeName : "\(safeName).mobileprovision"
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("forgesign-\(UUID().uuidString)-\(filename)")
        do {
            try data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
        } catch {
            return .failure(.copyFailed)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return importProfile(from: temporaryURL)
    }

    func delete(_ record: ProfileRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
        profiles.removeAll { $0.id == record.id }
        if selectedID == record.id {
            selectedID = profiles.first?.id
        }
        save()
    }

    func select(_ id: UUID?) {
        selectedID = id
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        // Load the cached records synchronously so the UI can render quickly.
        // Authenticity checks and profile parsing are refreshed off the main
        // actor below.
        profiles = index.profiles.filter {
            FileManager.default.fileExists(atPath: fileURL(for: $0).path)
        }
        selectedID = index.selectedID
        if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = profiles.first?.id
        }
    }

    private func refreshMetadataInBackground() {
        refreshTask?.cancel()
        let snapshot = profiles
        let directory = dir
        guard !snapshot.isEmpty else {
            isRefreshingMetadata = false
            return
        }
        isRefreshingMetadata = true

        refreshTask = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                snapshot.map { profile -> RefreshResult in
                    let url = directory.appendingPathComponent(profile.filename)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return RefreshResult(id: profile.id, record: nil)
                    }
                    let verified = ProfileAuthenticityChecker.isAuthentic(url)
                    guard let data = try? Data(contentsOf: url),
                          let info = ProvisioningProfileInspector.inspect(data: data) else {
                        return RefreshResult(id: profile.id,
                                             record: profile.withAuthenticity(false))
                    }
                    return RefreshResult(id: profile.id,
                                         record: profile.refreshed(with: info,
                                                                   authenticity: verified))
                }
            }.value

            guard let self else { return }
            guard !Task.isCancelled else {
                self.isRefreshingMetadata = false
                self.refreshTask = nil
                return
            }
            let refreshed = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.record) })
            // Preserve profiles imported while the background refresh was in
            // flight, while still dropping records whose file disappeared.
            self.profiles = self.profiles.compactMap { current in
                guard let record = refreshed[current.id] else { return current }
                return record
            }
            if self.selectedID == nil || !self.profiles.contains(where: { $0.id == self.selectedID }) {
                self.selectedID = self.profiles.first?.id
            }
            self.isRefreshingMetadata = false
            self.save()
            self.refreshTask = nil
        }
    }

    private func save() {
        let index = Index(profiles: profiles, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(index) {
            try? ProtectedPersistence.write(data, to: indexURL)
        }
    }
}

/// Parses the plist embedded inside a signed .mobileprovision blob and pulls
/// out the identity, coverage, and expiry fields ForgeSign surfaces. The CMS
/// signature itself is not verified here — zsign validates the profile when
/// signing.
struct ProvisioningProfileMetadata: Equatable, Sendable {
    let name: String
    let uuid: String?
    let teamID: String?
    let applicationIdentifier: String?
    let expirationDate: Date?
    let provisionedDevices: [String]
    let provisionsAllDevices: Bool?
    let getTaskAllow: Bool?
    let appGroups: [String]
    let keychainAccessGroups: [String]
    let developerCertificateSHA256: [String]
}

enum ProvisioningProfileInspector {
    static func inspect(data: Data) -> ProvisioningProfileMetadata? {
        // The DER/CMS wrapper around the payload is binary, so the whole file
        // can never be decoded as a String. Slice out the embedded plist by
        // its magic markers and let PropertyListSerialization parse it.
        for probe in probeSlices(in: data) {
            guard let plist = try? PropertyListSerialization.propertyList(from: probe,
                                                                          options: [],
                                                                          format: nil),
                  let dict = plist as? [String: Any]
            else { continue }

            let name = dict["Name"] as? String
                ?? (dict["ProfileName"] as? String)
                ?? "Provisioning Profile"

            let entitlements = dictionaryValue(dict["Entitlements"])
            let entitlementTeamID = stringValue(entitlements?["com.apple.developer.team-identifier"])
            let teamID: String?
            if let teamArray = dict["TeamIdentifier"] as? [String], let firstTeam = teamArray.first {
                teamID = firstTeam
            } else {
                teamID = (dict["TeamIdentifier"] as? String) ?? entitlementTeamID
            }

            let applicationIdentifier = stringValue(entitlements?["application-identifier"])
                ?? stringValue(entitlements?["com.apple.application-identifier"])
                ?? stringValue(dict["application-identifier"])
                ?? stringValue(dict["com.apple.application-identifier"])
            let provisionedDevices = dict["ProvisionedDevices"] as? [String] ?? []
            let provisionsAllDevices = dict["ProvisionsAllDevices"] as? Bool
            let getTaskAllow = entitlements?["get-task-allow"] as? Bool
            let appGroups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
            let keychainGroups = entitlements?["keychain-access-groups"] as? [String] ?? []
            let certificates = dict["DeveloperCertificates"] as? [Data] ?? []
            let certificateHashes = certificates.map { certificate in
                SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
            }
            return ProvisioningProfileMetadata(
                name: name,
                uuid: dict["UUID"] as? String,
                teamID: teamID,
                applicationIdentifier: applicationIdentifier,
                expirationDate: dict["ExpirationDate"] as? Date,
                provisionedDevices: provisionedDevices,
                provisionsAllDevices: provisionsAllDevices,
                getTaskAllow: getTaskAllow,
                appGroups: appGroups,
                keychainAccessGroups: keychainGroups,
                developerCertificateSHA256: certificateHashes
            )
        }
        return nil
    }

    /// A .mobileprovision is a CMS/PKCS#7 blob. Its signed payload is usually
    /// an XML plist (Xcode style), so we slice from `<?xml` to `</plist>`. As a
    /// fallback we also probe a `bplist00` binary plist (trimmed at the end of
    /// the file, where the CMS blob typically ends right after the plist).
    private static func probeSlices(in data: Data) -> [Data] {
        var slices: [Data] = []

        let xmlMagic = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        if let start = data.range(of: xmlMagic),
           let end = data.range(of: plistEnd, in: start.upperBound..<data.endIndex) {
            slices.append(data.subdata(in: start.lowerBound..<end.upperBound))
        }

        let binaryMagic = Data("bplist00".utf8)
        if let start = data.range(of: binaryMagic) {
            slices.append(data.subdata(in: start.lowerBound..<data.endIndex))
        }

        return slices
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let dictionary = value as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
