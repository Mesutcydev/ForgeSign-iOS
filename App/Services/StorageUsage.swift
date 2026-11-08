import Foundation

/// Reads only files owned by one ForgeSign storage directory. Directory scans
/// happen on appearance or after a storage change, not while rows render.
enum StorageUsage {
    static func files(in directory: URL, extensions: Set<String>) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        return urls.filter { url in
            extensions.contains(url.pathExtension.lowercased())
                && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
        }
    }

    static func bytes(of files: [URL]) -> Int64 {
        files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
