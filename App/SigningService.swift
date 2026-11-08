import Foundation
import UniformTypeIdentifiers

/// Bridges the zsign C++ engine into Swift and manages file staging.
@MainActor
final class SigningService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case provisioning
        case signing
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var stagingResetID = 0
    @Published private(set) var activeInputChecks = 0
    @Published private(set) var isStaging = false
    @Published private(set) var copyProgress: TransferProgress?
    private var activeCopy: FileCopyOperation?
    private var activeCopyID: UUID?

    var isBusy: Bool { phase == .signing || phase == .provisioning }
    var canAcceptInput: Bool { !isBusy && !isStaging && activeInputChecks == 0 }

    let tempDir: URL
    let workDir: URL

    init(workDirectory: URL? = nil) {
        let base = workDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForgeSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workDir = base
        tempDir = base.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileCopyOperation.removeAbandonedPartials(in: base)
        // Partial extracts and injected IPA copies never survive a relaunch.
        cleanTemp()
    }

    /// Purges the disposable temp folder (partial extracts, injected IPA copies).
    /// Skipped while an input inspection is reading from tempDir — otherwise a
    /// sign completing during a newly staged inspection would delete the files
    /// under it. The leftovers go on the next clean-up or relaunch.
    func cleanTemp() {
        guard activeInputChecks == 0 else { return }
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
        let keptPath = kept?.standardizedFileURL.path
        let archiveExtensions: Set<String> = ["ipa", "zip"]
        for item in items {
            guard item.standardizedFileURL.path != keptPath,
                  archiveExtensions.contains(item.pathExtension.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    var stagedBytes: Int64 {
        StorageUsage.bytes(of: StorageUsage.files(in: workDir, extensions: ["ipa", "zip", "dylib"]))
    }

    var canClearStaging: Bool {
        canAcceptInput
    }

    func beginInputCheck() { activeInputChecks += 1 }
    func endInputCheck() { activeInputChecks = max(0, activeInputChecks - 1) }

    /// Discards the currently staged input and optional injected library.
    /// The Sign view observes stagingResetID and drops its stale URLs.
    @discardableResult
    func clearStaging() -> (removed: Int, failed: Int) {
        guard canClearStaging else { return (0, 0) }
        var removed = 0
        var failed = 0
        for url in StorageUsage.files(in: workDir, extensions: ["ipa", "zip", "dylib"]) {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                failed += 1
            }
        }
        if removed > 0 { stagingResetID += 1 }
        return (removed, failed)
    }

    func cancelInputCopy() { activeCopy?.cancel() }

    /// Copies off the main actor while retaining the scoped access grant.
    func stage(_ url: URL, as name: String? = nil) async throws -> URL {
        guard canAcceptInput else { throw FileCopyOperation.Failure.busy }
        let destination = workDir.appendingPathComponent(name ?? url.lastPathComponent).standardizedFileURL
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath() == workDir.resolvingSymlinksInPath(),
              destination != workDir.standardizedFileURL else { throw FileCopyOperation.Failure.invalidDestination }
        let id = UUID()
        let operation = FileCopyOperation { [weak self] progress in
            Task { @MainActor in
                guard let self, self.activeCopyID == id else { return }
                self.copyProgress = progress
            }
        }
        activeCopy = operation
        activeCopyID = id
        isStaging = true
        copyProgress = nil
        defer {
            activeCopy = nil
            activeCopyID = nil
            isStaging = false
            copyProgress = nil
        }
        return try await operation.copy(from: url, to: destination)
    }

    /// Runs the zsign signing engine. Blocking — call from a background task.
    /// Returns success, a message, the signed bundle identifier, and version.
    nonisolated static func sign(ipa: URL, p12: URL, password: String, profiles: [URL],
                      bundleId: String, output: URL, tempDir: URL,
                      removeExtensions: Bool, enableDocuments: Bool,
                      matchAppEntitlements: Bool = false)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {
        #if !FORGE_BRIDGE
        // UI-preview builds (e.g. the simulator target) omit the zsign engine.
        return (false, "Signing engine unavailable in this build.", "", "1.0")
        #else
        var msgBuf = [CChar](repeating: 0, count: 1024)
        var bidBuf = [CChar](repeating: 0, count: 512)
        var verBuf = [CChar](repeating: 0, count: 128)
        let profilePaths = profiles.map(\.path).joined(separator: "\n")
        let status = forgesign_sign_ipa_profiles(
            ipa.path, p12.path, password, profilePaths,
            bundleId.isEmpty ? nil : bundleId,
            output.path,
            tempDir.path,
            removeExtensions ? 1 : 0,
            enableDocuments ? 1 : 0,
            matchAppEntitlements ? 1 : 0,
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

    nonisolated static func verify(ipa: URL, temporaryDirectory: URL) -> (ok: Bool, message: String) {
        #if !FORGE_BRIDGE
        return (false, "Signed IPA verification is unavailable in this build.")
        #else
        var messageBuffer = [CChar](repeating: 0, count: 1024)
        let status = forgesign_verify_ipa(
            ipa.path,
            temporaryDirectory.path,
            &messageBuffer,
            Int32(messageBuffer.count)
        )
        let message = String(decoding: messageBuffer.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (status == 0, message.isEmpty ? (status == 0 ? "Signed IPA verified." : "Signed IPA verification failed.") : message)
        #endif
    }

    nonisolated static func validateSigningAsset(p12: URL, password: String, profile: URL)
        -> (ok: Bool, message: String) {
        #if !FORGE_BRIDGE
        return (true, "Validation is deferred to the device signing engine.")
        #else
        var messageBuffer = [CChar](repeating: 0, count: 512)
        let status = forgesign_validate_signing_asset(
            p12.path, password, profile.path,
            &messageBuffer, Int32(messageBuffer.count)
        )
        let message = String(decoding: messageBuffer.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (status == 0,
                message.isEmpty ? (status == 0 ? "Certificate and profile match." : "Certificate/profile validation failed.") : message)
        #endif
    }

}
