import Foundation

struct SourceFeed: Codable {
    let name: String
    let identifier: String?
    let apps: [FeedApp]
}

struct FeedApp: Codable, Hashable {
    let bundleIdentifier: String
    let title: String?
    let developer: String?
    let description: String?
    let iconURL: URL?
    let versions: [FeedVersion]
    let tags: [String]?

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    static func == (lhs: FeedApp, rhs: FeedApp) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

struct FeedVersion: Codable, Hashable {
    let version: String
    let downloadURL: URL
    let size: Int64?
}
