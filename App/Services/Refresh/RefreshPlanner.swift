import Foundation

// MARK: - Refresh capability
//
// Refresh is not "reinstall": it re-uses ForgeSign's signing pipeline and then
// installs the result as an *upgrade* so the app's data survives. It is only
// offered when every input it needs is actually present; otherwise the Library
// says what is missing instead of pretending it will happen automatically.

enum AppRefreshCapability: Equatable, Sendable {
    /// Everything needed is on device: a retained source, saved credentials, and a transport.
    case automatic(reason: String)
    /// Possible, but a human has to supply something first (password, sign-in, source pick).
    case interactive(reason: String)
    /// The signed app can be re-signed and installed fresh, but not updated in place.
    case reinstallOnly(reason: String)
    case unsupported(reason: String)

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .automatic: return "auto"
        case .interactive: return "action needed"
        case .reinstallOnly: return "reinstall"
        case .unsupported: return "unsupported"
        }
    }

    var reason: String {
        switch self {
        case .automatic(let reason), .interactive(let reason),
             .reinstallOnly(let reason), .unsupported(let reason):
            return reason
        }
    }
}

struct RefreshInputs: Equatable, Sendable {
    /// A retained copy of the package exactly as it was imported.
    var hasRefreshSource: Bool
    /// The signing certificate's password is in the Keychain.
    var hasCertificatePassword: Bool
    /// Apple Account credentials are on hand for provisioning.
    var hasAppleAccount: Bool
    /// The transport that would install the result exists in this build.
    var hasInstallTransport: Bool
    /// The stored expiry of the profiles inside the signed app.
    var profileExpiresAt: Date?
}

enum RefreshPlanner {
    /// How long before expiry a refresh should happen.
    static let refreshWindow: TimeInterval = 48 * 3600

    static func capability(for inputs: RefreshInputs, now: Date = Date()) -> AppRefreshCapability {
        guard inputs.hasInstallTransport else {
            return .unsupported(reason: "No installation transport is available in this build.")
        }
        if let expiry = inputs.profileExpiresAt, expiry <= now {
            // Expired apps cannot be upgraded in place with an expired profile.
            return .interactive(reason: "The embedded profile has expired; refresh now to re-provision.")
        }
        guard inputs.hasRefreshSource else {
            return .interactive(reason: "The original IPA was not kept. Pick the package again to refresh.")
        }
        guard inputs.hasCertificatePassword else {
            return .interactive(reason: "The certificate password is not saved, so a refresh needs you to enter it.")
        }
        guard inputs.hasAppleAccount else {
            return .interactive(reason: "Signing needs a certificate and profile, or Apple Account provisioning.")
        }
        return .automatic(reason: "Ready to re-sign and upgrade in place.")
    }

    /// True when the app is inside the refresh window (or already expired).
    static func shouldRefresh(expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) <= refreshWindow
    }

    /// "Expires in 2d 7h", "Expires today", "Expired 3d ago", or nil when unknown.
    static func expiryText(_ expiry: Date?, now: Date = Date()) -> String? {
        guard let expiry else { return nil }
        let interval = expiry.timeIntervalSince(now)
        if interval <= 0 {
            let days = Int(abs(interval) / 86_400)
            return days >= 1 ? "Expired \(days)d ago" : "Expired"
        }
        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days >= 1 { return "Expires in \(days)d \(hours)h" }
        if hours >= 1 { return "Expires in \(hours)h" }
        return "Expires today"
    }
}

/// Foreground scan: which library entries need attention. iOS background
/// execution is not claimed, so this runs when the app becomes active.
struct RefreshScan: Equatable, Sendable {
    let due: [UUID]
    let expiringSoonCount: Int

    static let empty = RefreshScan(due: [], expiringSoonCount: 0)

    var summary: String? {
        guard expiringSoonCount > 0 else { return nil }
        return expiringSoonCount == 1
            ? "1 app expires within 48h"
            : "\(expiringSoonCount) apps expire within 48h"
    }
}

enum RefreshScanner {
    static func scan(_ records: [SigningRecord], now: Date = Date()) -> RefreshScan {
        let due = records
            .filter { RefreshPlanner.shouldRefresh(expiry: $0.profileExpiresAt, now: now) }
            .sorted { ($0.profileExpiresAt ?? now) < ($1.profileExpiresAt ?? now) }
            .map(\.id)
        return RefreshScan(due: due, expiringSoonCount: due.count)
    }
}

// MARK: - Refresh sources

/// Keeps the *original* imported package so a refresh can re-sign the same
/// input. The signed artifact is never used as its own source.
@MainActor
final class RefreshSourceStore: ObservableObject {
    static let defaultBudget: Int64 = 1_500_000_000 // 1.5 GB across all sources

    let directory: URL
    private let manifestURL: URL
    private let budget: Int64
    @Published private var entries: [Entry]

    private struct Entry: Codable, Equatable {
        var recordID: UUID
        var filename: String
        var sourceName: String
        var addedAt: Date
        var byteCount: Int64
    }

    init(directory: URL? = nil, budget: Int64 = RefreshSourceStore.defaultBudget) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RefreshSources", isDirectory: true)
        self.directory = base
        self.manifestURL = base.appendingPathComponent("manifest.json")
        self.budget = budget
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        entries = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteCount } }

    func sourceURL(for recordID: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.recordID == recordID }) else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func sourceName(for recordID: UUID) -> String? {
        entries.first(where: { $0.recordID == recordID })?.sourceName
    }

    /// Copies the imported package next to the library index. Returns the stored
    /// filename, or nil when the copy is refused (too big / unreadable).
    @discardableResult
    func retain(_ source: URL, for recordID: UUID, now: Date = Date()) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= budget else { return nil }

        let filename = "\(recordID.uuidString).ipa"
        let destination = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }

        entries.removeAll { $0.recordID == recordID }
        entries.append(Entry(recordID: recordID,
                             filename: filename,
                             sourceName: source.lastPathComponent,
                             addedAt: now,
                             byteCount: size))
        prune()
        save()
        return filename
    }

    func removeSource(for recordID: UUID) {
        if let entry = entries.first(where: { $0.recordID == recordID }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
        }
        entries.removeAll { $0.recordID == recordID }
        save()
    }

    func removeAll() {
        entries.forEach { try? FileManager.default.removeItem(at: directory.appendingPathComponent($0.filename)) }
        entries.removeAll()
        save()
    }

    /// Oldest first, until the budget fits. Never keeps more than the budget.
    func prune() {
        while totalBytes > budget, let oldest = entries.min(by: { $0.addedAt < $1.addedAt }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldest.filename))
            entries.removeAll { $0.recordID == oldest.recordID }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? ProtectedPersistence.write(data, to: manifestURL)
    }
}