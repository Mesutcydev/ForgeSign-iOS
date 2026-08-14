import Foundation

struct ProfileRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let name: String?
    let teamID: String?
    let applicationIdentifier: String?
    let notAfter: Date?
    let provisionedDeviceCount: Int?
    let provisionsAllDevices: Bool?
    let getTaskAllow: Bool?
    let profileIsAuthentic: Bool
    let addedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, filename, name, teamID, applicationIdentifier, notAfter
        case provisionedDeviceCount, provisionsAllDevices, getTaskAllow
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
        profileIsAuthentic = try values.decodeIfPresent(Bool.self, forKey: .profileIsAuthentic) ?? false
        addedAt = try values.decode(Date.self, forKey: .addedAt)
    }

    init(id: UUID, filename: String, name: String?, teamID: String?, applicationIdentifier: String?,
         notAfter: Date?, provisionedDeviceCount: Int?, provisionsAllDevices: Bool?, getTaskAllow: Bool?,
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
        self.profileIsAuthentic = profileIsAuthentic
        self.addedAt = addedAt
    }

    var displayName: String { name ?? filename }

    func withAuthenticity(_ value: Bool) -> ProfileRecord {
        ProfileRecord(id: id, filename: filename, name: name, teamID: teamID,
                      applicationIdentifier: applicationIdentifier, notAfter: notAfter,
                      provisionedDeviceCount: provisionedDeviceCount,
                      provisionsAllDevices: provisionsAllDevices, getTaskAllow: getTaskAllow,
                      profileIsAuthentic: value, addedAt: addedAt)
    }
}

/// Remembers imported provisioning profiles (.mobileprovision) on-device
/// (Application Support) so they survive app restarts, exactly like the
/// certificate store.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ProfileRecord] = []
    @Published var selectedID: UUID?

    private let dir: URL
    private let indexURL: URL

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
            provisionedDeviceCount: info.provisionedDeviceCount,
            provisionsAllDevices: info.provisionsAllDevices,
            getTaskAllow: info.getTaskAllow,
            profileIsAuthentic: true,
            addedAt: .now
        )

        profiles.append(record)
        selectedID = record.id
        save()
        return .success(record)
    }

    func delete(_ record: ProfileRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
        profiles.removeAll { $0.id == record.id }
        if selectedID == record.id {
            selectedID = profiles.first?.id
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        profiles = index.profiles.compactMap { profile in
            guard FileManager.default.fileExists(atPath: fileURL(for: profile).path) else { return nil }
            let verified = ProfileAuthenticityChecker.isAuthentic(fileURL(for: profile))
            return profile.profileIsAuthentic == verified ? profile : profile.withAuthenticity(verified)
        }
        selectedID = index.selectedID
        if selectedID == nil { selectedID = profiles.first?.id }
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
enum ProvisioningProfileInspector {
    static func inspect(data: Data) -> (name: String, teamID: String?, applicationIdentifier: String?, expirationDate: Date?, provisionedDeviceCount: Int?, provisionsAllDevices: Bool?, getTaskAllow: Bool?)? {
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

            let entitlements = dict["Entitlements"] as? [String: Any]
            let entitlementTeamID = entitlements?["com.apple.developer.team-identifier"] as? String
            let teamID: String?
            if let teamArray = dict["TeamIdentifier"] as? [String], let firstTeam = teamArray.first {
                teamID = firstTeam
            } else {
                teamID = (dict["TeamIdentifier"] as? String) ?? entitlementTeamID
            }

            let applicationIdentifier = entitlements?["application-identifier"] as? String
            let provisionedDeviceCount = (dict["ProvisionedDevices"] as? [Any])?.count
            let provisionsAllDevices = dict["ProvisionsAllDevices"] as? Bool
            let getTaskAllow = entitlements?["get-task-allow"] as? Bool
            return (name, teamID, applicationIdentifier, dict["ExpirationDate"] as? Date,
                    provisionedDeviceCount, provisionsAllDevices, getTaskAllow)
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
}
