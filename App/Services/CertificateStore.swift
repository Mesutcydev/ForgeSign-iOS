import Foundation
import Security

struct CertificateRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let commonName: String?
    let organization: String?
    let teamID: String?
    let notAfter: Date?
    let addedAt: Date
    var hasSavedPassword: Bool

    var displayName: String { commonName ?? filename }
}

/// Remembers imported signing certificates on-device (Application Support)
/// and optionally their passwords in the Keychain.
@MainActor
final class CertificateStore: ObservableObject {
    @Published private(set) var certificates: [CertificateRecord] = []
    @Published var selectedID: UUID?

    private let dir: URL
    private let indexURL: URL

    private struct Index: Codable {
        var certificates: [CertificateRecord] = []
        var selectedID: UUID?
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Certificates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = base.appendingPathComponent("certificates.json")
        load()
    }

    var selected: CertificateRecord? {
        certificates.first { $0.id == selectedID }
    }

    func fileURL(for record: CertificateRecord) -> URL {
        dir.appendingPathComponent(record.filename)
    }

    func savedPassword(for record: CertificateRecord) -> String? {
        PasswordVault.password(for: record.id)
    }

    enum ImportError: LocalizedError {
        case unreadable
        case badPassword
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .badPassword: return "Wrong password, or not a valid signing certificate."
            case .copyFailed: return "The certificate could not be saved."
            }
        }
    }

    /// Validates the p12 against the password, stores it on-device and selects it.
    @discardableResult
    func importCertificate(from source: URL, password: String, rememberPassword: Bool)
        -> Result<CertificateRecord, ImportError> {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: source) else { return .failure(.unreadable) }
        guard let info = P12Inspector.inspect(data: data, password: password) else {
            return .failure(.badPassword)
        }

        var filename = source.lastPathComponent
        if certificates.contains(where: { $0.filename == filename }) {
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

        var record = CertificateRecord(
            id: UUID(),
            filename: filename,
            commonName: info.commonName,
            organization: info.organization,
            teamID: info.teamID,
            notAfter: info.notAfter,
            addedAt: .now,
            hasSavedPassword: false
        )

        if rememberPassword {
            PasswordVault.save(password, for: record.id)
            record.hasSavedPassword = true
        }

        certificates.append(record)
        selectedID = record.id
        save()
        return .success(record)
    }

    func delete(_ record: CertificateRecord) {
        PasswordVault.delete(for: record.id)
        try? FileManager.default.removeItem(at: fileURL(for: record))
        certificates.removeAll { $0.id == record.id }
        if selectedID == record.id {
            selectedID = certificates.first?.id
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        certificates = index.certificates.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        selectedID = index.selectedID
        if selectedID == nil { selectedID = certificates.first?.id }
    }

    private func save() {
        let index = Index(certificates: certificates, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .completeFileProtection)
        }
    }
}

/// Passwords for remembered certificates. Prefers the iOS Keychain; when the
/// Keychain is unavailable (e.g. an ad-hoc signed build without the
/// application-identifier entitlement), falls back to a file protected by
/// iOS data protection (completeFileProtection).
enum PasswordVault {
    private static let service = "com.forgesign.mobile.p12"

    private static let fallbackDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PassVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fallbackURL(for id: UUID) -> URL {
        fallbackDir.appendingPathComponent(id.uuidString)
    }

    static func save(_ password: String, for id: UUID) {
        delete(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(password.utf8)
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess {
            return
        }
        try? Data(password.utf8).write(to: fallbackURL(for: id), options: .completeFileProtection)
    }

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        }
        if let data = try? Data(contentsOf: fallbackURL(for: id)) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL(for: id))
    }
}
