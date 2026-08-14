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
}

enum ForgeDiagnostic: LocalizedError, Equatable, Sendable {
    case persistence
    case importFailure
    case archive
    case network
    case signing
    case install

    var errorDescription: String? {
        switch self {
        case .persistence: return "ForgeSign could not save its local data. Check available storage and try again."
        case .importFailure: return "The selected file could not be imported. Choose it again or check its format."
        case .archive: return "The IPA archive is invalid or unsafe to process."
        case .network: return "The network response was invalid or unavailable."
        case .signing: return "Signing failed before a verified IPA could be created."
        case .install: return "The install handoff did not complete. Retry while ForgeSign remains open."
        }
    }
}
