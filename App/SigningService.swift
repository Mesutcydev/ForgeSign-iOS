import Foundation
import UniformTypeIdentifiers

/// Bridges the zsign C++ engine into Swift and manages file staging.
@MainActor
final class SigningService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signing
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    let tempDir: URL
    let workDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForgeSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workDir = base
        tempDir = base.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Partial extracts and injected IPA copies never survive a relaunch.
        cleanTemp()
    }

    /// Purges the disposable temp folder (partial extracts, injected IPA copies).
    func cleanTemp() {
        if let items = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    /// Removes previously staged IPA/zip files, keeping only the current pick
    /// so the staging area never grows beyond one archive + one dylib.
    func pruneStagedArchives(keeping kept: URL?) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) else { return }
        let archiveExtensions: Set<String> = ["ipa", "zip"]
        for item in items {
            guard item != kept, archiveExtensions.contains(item.pathExtension.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Copies a security-scoped picked file into the app container, returning the local path.
    func stage(_ url: URL, as name: String? = nil) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = workDir.appendingPathComponent(name ?? url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Runs the zsign signing engine. Blocking — call from a background task.
    /// Returns success, a message, the signed bundle identifier, and version.
    nonisolated static func sign(ipa: URL, p12: URL, password: String, profile: URL,
                     bundleId: String, output: URL, tempDir: URL,
                     removeExtensions: Bool, enableDocuments: Bool)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {
        #if !FORGE_BRIDGE
        // UI-preview builds (e.g. the simulator target) omit the zsign engine.
        return (false, "Signing engine unavailable in this build.", "", "1.0")
        #else
        var msgBuf = [CChar](repeating: 0, count: 1024)
        var bidBuf = [CChar](repeating: 0, count: 512)
        var verBuf = [CChar](repeating: 0, count: 128)
        let status = forgesign_sign_ipa(
            ipa.path, p12.path, password, profile.path,
            bundleId.isEmpty ? nil : bundleId,
            output.path,
            tempDir.path,
            removeExtensions ? 1 : 0,
            enableDocuments ? 1 : 0,
            &msgBuf, Int32(msgBuf.count),
            &bidBuf, Int32(bidBuf.count),
            &verBuf, Int32(verBuf.count)
        )
        let message = String(decoding: msgBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let signedId = String(decoding: bidBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let signedVersion = String(decoding: verBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (status == 0, message.isEmpty ? (status == 0 ? "Signed." : "Failed.") : message,
                signedId, signedVersion.isEmpty ? "1.0" : signedVersion)
        #endif
    }

    func cleanStaged() {
        if let items = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent != "tmp" {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
