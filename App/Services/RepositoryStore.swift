import Foundation

// MARK: - Persisted repository record

/// A user-added app source (AltStore-style). Only the URL + a display name are
/// persisted; the fetched catalog is kept in memory and re-fetched on demand.
struct Repository: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, name: String, addedAt: Date = .now) {
        self.id = id
        self.url = url
        self.name = name
        self.addedAt = addedAt
    }
}

// MARK: - AltStore source JSON (lenient)

/// A decoded AltStore/SideStore source. Decoding is deliberately forgiving: one
/// malformed app entry is skipped rather than failing the whole feed, and every
/// non-essential field is optional — this is untrusted data off the network.
struct RepoSource: Decodable, Equatable {
    let name: String?
    let identifier: String?
    let iconURL: URL?
    let apps: [RepoApp]

    private enum CodingKeys: String, CodingKey { case name, identifier, iconURL, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        identifier = try? c.decodeIfPresent(String.self, forKey: .identifier)
        iconURL = LenientDecode.url(c, .iconURL)
        // Skip individual bad entries instead of nuking the entire list.
        let raw = (try? c.decode([FailableApp].self, forKey: .apps)) ?? []
        apps = raw.compactMap(\.value)
    }

    /// Wrapper so a single un-decodable app doesn't fail the whole array.
    private struct FailableApp: Decodable {
        let value: RepoApp?
        init(from decoder: Decoder) throws { value = try? RepoApp(from: decoder) }
    }
}

/// A published version in a source catalog. Keeping the complete version list
/// lets the UI explain update history while the existing download path still
/// uses the same first-version fields as before.
struct RepoVersion: Decodable, Equatable, Identifiable {
    let version: String?
    let downloadURL: URL?
    let size: Int64?

    var id: String {
        "\(version ?? "")|\(downloadURL?.absoluteString ?? "")"
    }

    init(version: String?, downloadURL: URL?, size: Int64?) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case version, downloadURL, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = LenientDecode.url(c, .downloadURL)
        size = LenientDecode.int64(c, .size)
    }
}

/// One app in a source. Handles both the flat v1 shape (`version`,
/// `downloadURL`, `size` at the top level) and the newer v2 shape where those
/// live in a `versions` array — the first version still drives downloads.
struct RepoApp: Decodable, Identifiable, Equatable {
    /// Source feeds do not guarantee a bundle identifier (or even uniqueness).
    /// Give each decoded entry its own durable identity so malformed catalogs
    /// cannot hand SwiftUI duplicate row IDs.
    let id: UUID
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let localizedDescription: String?
    let iconURL: URL?
    let version: String?
    let downloadURL: URL?
    let size: Int64?
    let versions: [RepoVersion]

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, localizedDescription
        case iconURL, version, downloadURL, size, versions
    }

    init(from decoder: Decoder) throws {
        id = UUID()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        bundleIdentifier = (try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        developerName = try? c.decodeIfPresent(String.self, forKey: .developerName)
        localizedDescription = try? c.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = LenientDecode.url(c, .iconURL)

        let flatVersion = try? c.decodeIfPresent(String.self, forKey: .version)
        let flatURL = LenientDecode.url(c, .downloadURL)
        let flatSize = LenientDecode.int64(c, .size)
        let decodedVersions = (try? c.decodeIfPresent([RepoVersion].self, forKey: .versions)) ?? []
        var uniqueVersions: [RepoVersion] = []
        var seenVersionIDs = Set<String>()
        for candidate in decodedVersions where seenVersionIDs.insert(candidate.id).inserted {
            uniqueVersions.append(candidate)
        }
        let first = uniqueVersions.first
        versions = uniqueVersions.isEmpty && (flatVersion != nil || flatURL != nil || flatSize != nil)
            ? [RepoVersion(version: flatVersion, downloadURL: flatURL, size: flatSize)]
            : uniqueVersions
        version = flatVersion ?? first?.version
        downloadURL = flatURL ?? first?.downloadURL
        size = flatSize ?? first?.size
    }
}

/// URLs and numbers in real-world feeds are inconsistent (bad URL strings,
/// sizes as strings). Decode them without throwing so one odd value can't sink
/// the whole parse.
private enum LenientDecode {
    static func url<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: s)
    }
    static func int64<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let n = try? c.decodeIfPresent(Int64.self, forKey: key) { return n }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

// MARK: - Store

/// Remembers added repositories on-device (Application Support), fetches their
/// AltStore JSON catalogs, and downloads an app's IPA into the container. A
/// completed download is surfaced via `pendingIPA` for the Sign tab to adopt.
@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []

    /// Last successfully fetched catalog per repository (in memory only).
    @Published var catalog: [UUID: RepoSource] = [:]
    @Published var fetchError: [UUID: String] = [:]
    @Published var loadingRepoID: UUID?

    /// Identity of the app currently downloading, if any.
    @Published var activeDownloadID: UUID?
    @Published var downloadError: String?

    /// Last successful catalog fetch per repository (drives the "updated" label).
    @Published private(set) var catalogFetchedAt: [UUID: Date] = [:]

    /// Set when a download finishes — the Sign tab observes this and loads it.
    @Published var pendingIPA: URL?

    private var activeDownloadTask: Task<Void, Never>?

    private let indexURL: URL
    private let downloadsDir: URL

    private struct Index: Codable { var repositories: [Repository] = [] }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        indexURL = base.appendingPathComponent("repositories.json")
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        load()
        #if DEBUG
        RepoSource._selfTest()
        #endif
    }

    // MARK: Repo list

    enum AddError: LocalizedError {
        case invalidURL, duplicate
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid http(s) repository URL."
            case .duplicate: return "That repository is already added."
            }
        }
    }

    @discardableResult
    func add(urlString: String) -> Result<Repository, AddError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              NetworkPolicy.validateHTTPS(url) else {
            return .failure(.invalidURL)
        }
        guard !repositories.contains(where: { $0.url == url }) else {
            return .failure(.duplicate)
        }
        let repo = Repository(url: url, name: url.host ?? trimmed)
        repositories.append(repo)
        save()
        return .success(repo)
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        catalog[repo.id] = nil
        fetchError[repo.id] = nil
        catalogFetchedAt[repo.id] = nil
        save()
    }

    // MARK: Networking

    func refresh(_ repo: Repository) async {
        loadingRepoID = repo.id
        fetchError[repo.id] = nil
        defer { if loadingRepoID == repo.id { loadingRepoID = nil } }
        guard NetworkPolicy.validateHTTPS(repo.url) else {
            fetchError[repo.id] = "Repository URLs must use HTTPS."
            return
        }
        do {
            var req = URLRequest(url: repo.url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                fetchError[repo.id] = "The repository server returned an error."
                return
            }
            // Catalogs are untrusted. Avoid a pathological source exhausting
            // the app's memory and being terminated by iOS.
            guard data.count <= 25 * 1_024 * 1_024 else {
                fetchError[repo.id] = "This repository catalog is too large to load safely."
                return
            }
            let source = try JSONDecoder().decode(RepoSource.self, from: data)
            catalog[repo.id] = source
            catalogFetchedAt[repo.id] = .now
            // Adopt the source's own display name once we know it.
            if let name = source.name, !name.isEmpty,
               let i = repositories.firstIndex(where: { $0.id == repo.id }),
               repositories[i].name != name {
                repositories[i].name = name
                save()
            }
        } catch {
            fetchError[repo.id] = error.localizedDescription
        }
    }

    func download(_ app: RepoApp) async {
        guard let url = app.downloadURL, NetworkPolicy.validateHTTPS(url) else {
            downloadError = "This app has no safe HTTPS download URL."
            return
        }
        activeDownloadID = app.id
        downloadError = nil
        defer { if activeDownloadID == app.id { activeDownloadID = nil } }
        do {
            let (tempURL, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                downloadError = "Download failed — the server returned an error."
                return
            }
            let values = try tempURL.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            let maximum: Int64 = 2 * 1024 * 1024 * 1024
            guard size > 0, size <= maximum, app.size == nil || app.size == size else {
                downloadError = "Download size did not match the catalog or exceeded the safe limit."
                return
            }
            let dest = downloadsDir.appendingPathComponent(Self.ipaName(for: app))
            let replacement = dest.deletingLastPathComponent()
                .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).partial")
            try FileManager.default.moveItem(at: tempURL, to: replacement)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: replacement)
            } else {
                try FileManager.default.moveItem(at: replacement, to: dest)
            }
            pendingIPA = dest
        } catch {
            downloadError = error.localizedDescription
        }
    }

    /// A safe on-disk filename like `AppName-1.2.3.ipa`.
    private static func ipaName(for app: RepoApp) -> String {
        let base = app.name.isEmpty ? app.id.uuidString : app.name
        let stem = base.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let version = app.version.map { "-\($0)" } ?? ""
        return "\(stem)\(version).ipa"
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        repositories = index.repositories
    }

    private func save() {
        let index = Index(repositories: repositories)
        if let data = try? JSONEncoder().encode(index) {
            try? ProtectedPersistence.write(data, to: indexURL)
        }
    }
}

#if DEBUG
extension RepoSource {
    /// Smallest check that fails if the lenient decoder breaks — decodes both the
    /// flat (v1) and versioned (v2) AltStore shapes. Called once at debug launch.
    static func _selfTest() {
        let flat = """
        {"name":"Flat","apps":[{"name":"A","bundleIdentifier":"com.a",
        "version":"1.0","downloadURL":"https://e.com/a.ipa","size":123}]}
        """.data(using: .utf8)!
        let versioned = """
        {"name":"V2","apps":[{"name":"B","bundleIdentifier":"com.b","versions":[
        {"version":"2.0","downloadURL":"https://e.com/b.ipa","size":"456"}]}]}
        """.data(using: .utf8)!
        let f = try! JSONDecoder().decode(RepoSource.self, from: flat)
        assert(f.apps.first?.downloadURL?.absoluteString == "https://e.com/a.ipa")
        assert(f.apps.first?.size == 123)
        assert(f.apps.first?.versions.count == 1)
        let v = try! JSONDecoder().decode(RepoSource.self, from: versioned)
        assert(v.apps.first?.version == "2.0")
        assert(v.apps.first?.downloadURL?.absoluteString == "https://e.com/b.ipa")
        assert(v.apps.first?.size == 456)
        assert(v.apps.first?.versions.count == 1)
    }
}
#endif
