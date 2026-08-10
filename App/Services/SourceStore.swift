import Foundation

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var apps: [FeedApp] = []
    @Published private(set) var lastUpdated: Date?
    @Published var sources: [URL] = [] {
        didSet { saveSources(); Task { await refreshAllIfNeeded(force: true) } }
    }

    @Published private(set) var perSourceError: [URL: Error] = [:]

    private let sourcesKey = "ForgeSign.AppSourcesV1"
    private let cacheDir: URL
    private let ttl: TimeInterval = 60 * 60 * 6

    init() {
        let fm = FileManager.default
        cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AppSources", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadSources()

        if sources.isEmpty {
            sources = [
                URL(string: "https://alt.getutm.app/apps.json")!,
                URL(string: "https://altstore.oatmealdome.me/apps.json")!
            ]
            saveSources()
        }

        Task { await refreshAllIfNeeded() }
    }

    private func loadSources() {
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let arr = try? JSONDecoder().decode([URL].self, from: data) {
            sources = arr
        } else {
            sources = []
        }
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    func refreshAllIfNeeded(force: Bool = false) async {
        if !force, let updated = lastUpdated, Date().timeIntervalSince(updated) < ttl { return }
        await refreshAll()
    }

    func refreshAll() async {
        perSourceError = [:]
        var merged = [String: FeedApp]()

        await withTaskGroup(of: (URL, Result<[FeedApp], Error>).self) { group in
            for url in sources {
                group.addTask {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let feed = try JSONDecoder().decode(SourceFeed.self, from: data)
                        return (url, .success(feed.apps))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }

            for await res in group {
                switch res.1 {
                case .success(let apps):
                    for app in apps {
                        if let existing = merged[app.bundleIdentifier] {
                            if app.versions.count > existing.versions.count {
                                merged[app.bundleIdentifier] = app
                            }
                        } else {
                            merged[app.bundleIdentifier] = app
                        }
                    }
                case .failure(let err):
                    perSourceError[res.0] = err
                }
            }
        }

        self.apps = Array(merged.values).sorted { ($0.title ?? $0.bundleIdentifier) < ($1.title ?? $1.bundleIdentifier) }
        self.lastUpdated = Date()
    }

    func addSource(_ urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if !sources.contains(url) {
            sources.append(url)
        }
    }

    func removeSource(_ url: URL) {
        sources.removeAll { $0 == url }
    }
}
