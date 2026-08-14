import Foundation

enum NetworkPolicy {
    static func validateHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else { return false }
        let blockedHosts = ["localhost", "127.0.0.1", "::1"]
        return !blockedHosts.contains(host.lowercased())
    }

    static func manifestIsValid(_ data: Data, packageURL: String, bundleID: String, version: String) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let items = root["items"] as? [[String: Any]],
              let first = items.first,
              let assets = first["assets"] as? [[String: Any]],
              let package = assets.first(where: { ($0["kind"] as? String) == "software-package" }),
              let url = package["url"] as? String,
              url == packageURL else { return false }
        guard let metadata = first["metadata"] as? [String: Any] else { return false }
        guard (metadata["bundle-identifier"] as? String) == bundleID else { return false }
        if !version.isEmpty, let manifestVersion = metadata["bundle-version"] as? String {
            return manifestVersion == version
        }
        return true
    }
}
