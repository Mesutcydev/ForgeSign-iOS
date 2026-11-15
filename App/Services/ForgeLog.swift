import Foundation

/// Plain-text record of signing on this device, kept so a failed sign can be
/// explained after the fact. Each sign attempt appends one record. When the
/// file passes the limit, the oldest records are dropped.
enum ForgeLog {
    static let defaultLimit = 256 * 1024

    /// Every file operation runs here, in order, so the main thread never
    /// waits on a rewrite of the log.
    private static let queue = DispatchQueue(label: "ForgeSign.signing-log")

    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ForgeSign", isDirectory: true)
            .appendingPathComponent("signing.log")
    }

    /// Appends text. Callers add their own line breaks.
    static func append(_ text: String, to url: URL = fileURL, limit: Int = defaultLimit) {
        queue.async { write(text, to: url, limit: limit) }
    }

    static func read(from url: URL = fileURL) -> String {
        queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    static func clear(at url: URL = fileURL) {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    /// One timestamped line for something that happens outside a sign attempt.
    static func event(_ message: String) {
        append("\(timestamp()) \(message)\n")
    }

    static func timestamp(_ date: Date = Date()) -> String {
        date.formatted(.iso8601)
    }

    private static func write(_ text: String, to url: URL, limit: Int) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var existing = ((try? String(contentsOf: url, encoding: .utf8)) ?? "") + text
        if existing.utf8.count > limit {
            // Keep the newest records, starting at a record boundary when one is in range.
            let tail = String(decoding: existing.utf8.suffix(limit), as: UTF8.self)
            if let boundary = tail.range(of: "\n=== ") {
                existing = String(tail[tail.index(after: boundary.lowerBound)...])
            } else {
                existing = tail
            }
        }
        guard let data = existing.data(using: .utf8),
              (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return }
        // The log holds signing details; keep it out of device backups.
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
