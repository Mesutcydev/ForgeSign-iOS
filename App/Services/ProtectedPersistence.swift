import Foundation

enum ProtectedPersistence {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try data.write(to: temporary, options: [.atomic, .completeFileProtection])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Result of reading a JSON index file.
    struct IndexLoad<Value> {
        let value: Value?
        /// False when an unreadable file could not be moved aside. Saving then
        /// would overwrite it, so the caller must not save.
        let safeToSave: Bool
    }

    /// Loads a JSON index. A file that exists but cannot be read or decoded is
    /// moved aside under a new name and never overwritten, so the next save
    /// starts a fresh index without erasing what was there (audit S4).
    static func loadIndex<Value: Decodable>(_ type: Value.Type, from url: URL) -> IndexLoad<Value> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return IndexLoad(value: nil, safeToSave: true)
        }
        if let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode(Value.self, from: data) {
            return IndexLoad(value: value, safeToSave: true)
        }
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let aside = url.appendingPathExtension("unreadable-\(stamp)")
        do {
            try fileManager.moveItem(at: url, to: aside)
            ForgeLog.event("Moved an unreadable index aside as \(aside.lastPathComponent). A new index starts now.")
            return IndexLoad(value: nil, safeToSave: true)
        } catch {
            ForgeLog.event("An unreadable index (\(url.lastPathComponent)) could not be moved aside. Changes will not be saved.")
            return IndexLoad(value: nil, safeToSave: false)
        }
    }

    /// Removes temporary copies left by an import that did not finish, for
    /// example after a crash. Runs at launch, when no import can be running (audit S8).
    static func sweepTemporaryImports() {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix("forgesign-") {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
