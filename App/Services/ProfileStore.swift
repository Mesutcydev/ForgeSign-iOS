import Foundation

struct ProfileRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let name: String?
    let teamID: String?
    let notAfter: Date?
    let addedAt: Date

    var displayName: String { name ?? filename }
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
            notAfter: info.expirationDate,
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
        profiles = index.profiles.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        selectedID = index.selectedID
        if selectedID == nil { selectedID = profiles.first?.id }
    }

    private func save() {
        let index = Index(profiles: profiles, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .completeFileProtection)
        }
    }
}

/// Parses the XML plist embedded inside a signed .mobileprovision blob and
/// pulls out the fields ForgeSign surfaces (name, team, expiry). The CMS
/// signature itself is not verified here — zsign validates the profile when
/// signing.
enum ProvisioningProfileInspector {
    static func inspect(data: Data) -> (name: String, teamID: String?, expirationDate: Date?)? {
        guard let xml = embeddedPlistXML(from: data),
              let plist = try? PropertyListSerialization.propertyList(from: xml,
                                                                      options: [],
                                                                      format: nil) as? [String: Any]
        else { return nil }

        let name = plist["Name"] as? String
            ?? (plist["ProfileName"] as? String)
            ?? "Provisioning Profile"

        let teamID: String?
        if let teamArray = plist["TeamIdentifier"] as? [String] {
            teamID = teamArray.first
        } else {
            teamID = plist["TeamIdentifier"] as? String
        }

        let expirationDate = plist["ExpirationDate"] as? Date
        return (name, teamID, expirationDate)
    }

    /// A .mobileprovision is a CMS/PKCS#7 blob whose signed payload is an XML
    /// plist. We locate that plist by scanning for its outer tags.
    private static func embeddedPlistXML(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .ascii) else { return nil }
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let xml = text[start.lowerBound...end.upperBound]
        return Data(xml.utf8)
    }
}
