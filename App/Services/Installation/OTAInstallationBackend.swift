import Foundation

/// The existing installation transport, wrapped — not rewritten.
///
/// It serves the signed IPA from the loopback HTTP server, validates the
/// trusted remote manifest, and hands `itms-services://` to iOS. Behaviour is
/// unchanged: the same `InstallController` drives it, including the keep-alive,
/// background task, Range support, Safari fallback, and delivery accounting.
///
/// Honest outcome: this transport cannot observe iOS finishing the install, so
/// it reports `.deliveredToSystem` and the library keeps the record in
/// `delivered` — never `installed`.
@MainActor
final class OTAInstallationBackend: IPAInstallationBackend {
    let method: InstallationMethod = .ota
    let displayName = InstallationMethod.ota.displayName

    private let controller: InstallController

    init(controller: InstallController) {
        self.controller = controller
    }

    func availability(for app: SignedAppMetadata) -> InstallationBackendAvailability {
        guard FileManager.default.fileExists(atPath: app.ipaURL.path) else {
            return .unavailable(reason: "The signed IPA is no longer in the Library.")
        }
        guard !app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(reason: "The signed IPA has no bundle identifier to install.")
        }
        return .available
    }

    func install(_ app: SignedAppMetadata,
                 progress: @escaping (InstallationProgress) -> Void) async throws -> InstallationReceipt {
        let stream = AsyncStream<InstallationProgress> { continuation in
            controller.onProgress = { event in
                progress(event)
                continuation.yield(event)
                if event.phase.isTerminal { continuation.finish() }
            }
        }

        controller.install(ipa: app.ipaURL,
                           bundleId: app.bundleIdentifier,
                           version: app.version,
                           recordID: nil)

        for await event in stream {
            if Task.isCancelled {
                controller.cancelInstall(markFailed: false)
                throw DeviceInstallError.cancelled
            }
            switch event.phase {
            case .delivered:
                // The handoff succeeded; the controller keeps serving the IPA
                // while iOS finishes, exactly as before.
                return InstallationReceipt(method: method,
                                           bundleIdentifier: app.bundleIdentifier,
                                           outcome: .deliveredToSystem,
                                           detail: event.message)
            case .completed:
                return InstallationReceipt(method: method,
                                           bundleIdentifier: app.bundleIdentifier,
                                           outcome: .deliveredToSystem,
                                           detail: event.message)
            case .cancelled:
                throw DeviceInstallError.cancelled
            case .failed(let message):
                throw DeviceInstallError.installRejected(Self.clean(message))
            default:
                continue
            }
        }

        throw DeviceInstallError.connectionLost
    }

    func cancel() {
        controller.cancelInstall(markFailed: false)
    }

    /// The controller reports failures as "Install failed: …"; the coordinator
    /// adds its own prefix, so keep only the reason.
    static func clean(_ status: String) -> String {
        let prefix = "Install failed:"
        guard status.hasPrefix(prefix) else { return status }
        return status.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}