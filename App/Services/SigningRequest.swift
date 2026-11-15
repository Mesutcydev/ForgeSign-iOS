import Foundation

/// An immutable snapshot of the run. Background signing never reads UI state
/// or mutable certificate/profile stores.
struct SigningRequest: Sendable {
    struct Profile: Sendable {
        let url: URL
        let name: String
        /// Re-checked here: the background metadata refresh can change it after the audit (audit S11).
        var isAuthentic: Bool = true
    }
    let ipa: URL
    let p12: URL
    let password: String
    let profiles: [Profile]
    let bundleID: String
    let output: URL
    let temporaryDirectory: URL
    let removeExtensions: Bool
    let enableDocuments: Bool
    let matchAppEntitlements: Bool
    let dylib: URL?
    let injectIntoExtensions: Bool
    var removeWatchApp: Bool = false
}

struct SignedOutput: Sendable {
    let url: URL
    let bundleID: String
    let version: String
    let message: String
}

struct SigningFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum SigningWorker {
    private static let queue = DispatchQueue(label: "ForgeSign.signing", qos: .userInitiated)

    static func run(_ request: SigningRequest) async -> Result<SignedOutput, SigningFailure> {
        await withCheckedContinuation { continuation in
            queue.async {
                _ = SigningService.takeLog()  // drop output left by an earlier attempt
                let outcome = perform(request)
                record(request, outcome, zsignLog: SigningService.takeLog())
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Writes one record per sign attempt to the signing log: the settings,
    /// the engine's output and the outcome. The certificate password is never written.
    private static func record(_ request: SigningRequest,
                               _ outcome: Result<SignedOutput, SigningFailure>,
                               zsignLog: String) {
        let bundle = request.bundleID.isEmpty ? "unchanged" : request.bundleID
        let profiles = request.profiles.map(\.name).joined(separator: ", ")
        var lines = [
            "=== Sign \(request.ipa.lastPathComponent) at \(ForgeLog.timestamp()) ===",
            "Bundle ID: \(bundle)",
            "Profiles: \(profiles)",
            "Options: remove extensions \(request.removeExtensions), remove Watch app \(request.removeWatchApp), "
                + "Files import \(request.enableDocuments), own entitlements \(request.matchAppEntitlements), "
                + "dylib \(request.dylib != nil)",
            zsignLog.isEmpty
                ? "Engine: no output, the attempt stopped before the signing engine ran."
                : "Engine output:\n" + zsignLog.trimmingCharacters(in: .newlines),
        ]
        switch outcome {
        case .success(let signed):
            lines.append("Result: signed \(signed.bundleID) \(signed.version)")
        case .failure(let failure):
            lines.append("Result: failed: \(failure.message)")
        }
        ForgeLog.append(lines.joined(separator: "\n") + "\n\n")
    }

    private static func perform(_ request: SigningRequest) -> Result<SignedOutput, SigningFailure> {
        guard !request.profiles.isEmpty else {
            return .failure(SigningFailure(message: "No matching provisioning profiles were supplied."))
        }
        let partial = request.temporaryDirectory.appendingPathComponent("signed-\(UUID().uuidString).ipa.partial")
        let injected = request.temporaryDirectory.appendingPathComponent("injected-\(UUID().uuidString).ipa")
        defer {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: injected)
        }
        for profile in request.profiles where !profile.isAuthentic {
            return .failure(SigningFailure(message: "Profile “\(profile.name)” failed validation. Re-import it, then try again."))
        }
        for profile in request.profiles {
            let validation = SigningService.validateSigningAsset(p12: request.p12, password: request.password, profile: profile.url)
            guard validation.ok else {
                return .failure(SigningFailure(message: "Profile “\(profile.name)” cannot be used with the selected certificate: \(validation.message)"))
            }
        }
        let input: URL
        if let dylib = request.dylib {
            switch DylibInjectionService.prepare(ipa: request.ipa, dylib: dylib, output: injected,
                                                 temporaryDirectory: request.temporaryDirectory,
                                                 injectIntoExtensions: request.injectIntoExtensions) {
            case .success: input = injected
            case .failure(let error): return .failure(SigningFailure(message: error.localizedDescription))
            }
        } else {
            input = request.ipa
        }
        let result = SigningService.sign(
            ipa: input, p12: request.p12, password: request.password, profiles: request.profiles.map(\.url),
            bundleId: request.bundleID, output: partial, tempDir: request.temporaryDirectory,
            removeExtensions: request.removeExtensions, enableDocuments: request.enableDocuments,
            matchAppEntitlements: request.matchAppEntitlements,
            removeWatchApp: request.removeWatchApp
        )
        guard result.ok else { return .failure(SigningFailure(message: result.message)) }
        if !request.bundleID.isEmpty && result.signedBundleId != request.bundleID {
            return .failure(SigningFailure(message: "The signed app has bundle ID \(result.signedBundleId), not \(request.bundleID). Nothing was saved."))
        }
        let verification = SigningService.verify(ipa: partial, temporaryDirectory: request.temporaryDirectory)
        guard verification.ok else { return .failure(SigningFailure(message: verification.message)) }
        do {
            // moveItem refuses to overwrite a destination created since planning.
            try FileManager.default.moveItem(at: partial, to: request.output)
            return .success(SignedOutput(url: request.output, bundleID: result.signedBundleId,
                                         version: result.signedVersion, message: result.message))
        } catch {
            return .failure(SigningFailure(message: "The signed IPA could not be finalized in the Library."))
        }
    }
}
