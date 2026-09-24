import Foundation

enum InstallationPhase: Equatable, Sendable {
    case idle
    case checkingEnvironment
    case preparingPackage
    case connecting
    case awaitingSystem
    case transferring(Double)
    case installing(Double)
    case verifying
    /// Handed to iOS; the system finishes the install in the background.
    case delivered
    /// Device-side installation reported success.
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .delivered, .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .checkingEnvironment, .preparingPackage, .connecting, .awaitingSystem, .transferring, .installing, .verifying: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .checkingEnvironment: return "Checking"
        case .preparingPackage: return "Preparing"
        case .connecting: return "Connecting"
        case .awaitingSystem: return "Waiting for iOS"
        case .transferring(let fraction): return "Transferring \(Int(fraction * 100))%"
        case .installing(let fraction): return "Installing \(Int(fraction * 100))%"
        case .verifying: return "Verifying"
        case .delivered: return "Delivered"
        case .completed: return "Installed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct InstallationProgress: Equatable, Sendable {
    let phase: InstallationPhase
    let message: String
    let fraction: Double?

    init(phase: InstallationPhase, message: String, fraction: Double? = nil) {
        self.phase = phase
        self.message = message
        self.fraction = fraction
    }
}

/// The single owner of installation: drives the OTA `InstallController`
/// (loopback server + itms-services) and mirrors its progress for the UI.
/// The controller posts the Library install state itself.
// ponytail: OTA only. The paired-device (idevice) transport was removed: it was
// never validated on hardware and double-freed its session on reuse. Restore
// from git (b4ac4d8) if a direct install path is wanted again.
@MainActor
final class InstallCoordinator: ObservableObject {
    @Published private(set) var phase: InstallationPhase = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastError: String?

    let controller: InstallController

    private var lastRequest: (ipa: URL, bundleId: String, version: String, recordID: UUID?)?

    var isInstalling: Bool { phase.isActive }

    init(controller: InstallController = InstallController()) {
        self.controller = controller
        controller.onProgress = { [weak self] progress in
            self?.apply(progress)
        }
    }

    func install(ipa: URL,
                 bundleId: String,
                 version: String,
                 recordID: UUID? = nil,
                 displayName: String? = nil) {
        guard !isInstalling else {
            statusMessage = "An installation is already running."
            return
        }
        lastRequest = (ipa, bundleId, version, recordID)
        lastError = nil
        guard FileManager.default.fileExists(atPath: ipa.path) else {
            apply(InstallationProgress(phase: .failed(""), message: "The signed IPA is no longer in the Library."))
            return
        }
        guard !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apply(InstallationProgress(phase: .failed(""), message: "The signed IPA has no bundle identifier to install."))
            return
        }
        controller.install(ipa: ipa, bundleId: bundleId, version: version, recordID: recordID)
    }

    func retry() {
        guard let request = lastRequest else { return }
        install(ipa: request.ipa, bundleId: request.bundleId,
                version: request.version, recordID: request.recordID)
    }

    func cancel() {
        controller.cancelInstall(markFailed: false)
    }

    private func apply(_ progress: InstallationProgress) {
        phase = progress.phase
        statusMessage = progress.message
        if case .failed = progress.phase { lastError = progress.message }
    }
}
