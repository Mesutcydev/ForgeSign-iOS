import Foundation

/// The single owner of installation. Signing produces a verified IPA; this
/// coordinator picks a transport, drives it, and updates the Signed library.
///
/// The concrete transports stay behind `IPAInstallationBackend`, so a new one
/// (paired direct install, remote AltServer) can be added without touching the
/// signing pipeline or the existing OTA behaviour.
@MainActor
final class InstallCoordinator: ObservableObject {
    @Published private(set) var phase: InstallationPhase = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastReceipt: InstallationReceipt?
    @Published private(set) var lastError: DeviceInstallError?
    @Published private(set) var fallbackMethods: [InstallationMethod] = []

    /// The requested transport. `automatic` prefers the most private working
    /// method: direct device, then remote AltServer, then OTA.
    @Published var method: InstallationMethod = .automatic

    let controller: InstallController

    private let backends: [IPAInstallationBackend]
    private var activeToken: UUID?
    private var lastRequest: Request?

    private struct Request {
        let metadata: SignedAppMetadata
        let recordID: UUID?
    }

    var isInstalling: Bool { activeToken != nil }

    /// Methods this build can actually run, in registration order.
    var availableMethods: [InstallationMethod] { backends.map(\.method) }

    init(controller: InstallController = InstallController(),
         backends: [IPAInstallationBackend]? = nil) {
        self.controller = controller
        self.backends = backends ?? Self.defaultBackends(controller: controller)
    }

    static func defaultBackends(controller: InstallController) -> [IPAInstallationBackend] {
        var backends: [IPAInstallationBackend] = []
        // Direct-device and remote-AltServer backends register here once their
        // transports are proven on a physical device. Until then only OTA exists,
        // so the Installation Method picker stays hidden and `automatic` resolves
        // to OTA.
        if FeatureFlags.directDeviceInstall {
            backends.append(DirectDeviceInstallationBackend())
        }
        backends.append(OTAInstallationBackend(controller: controller))
        return backends
    }

    // MARK: - Availability

    func availability(for app: SignedAppMetadata) -> [InstallationBackendSelection.Candidate] {
        backends.map {
            InstallationBackendSelection.Candidate(method: $0.method, availability: $0.availability(for: app))
        }
    }

    // MARK: - Install

    func install(ipa: URL,
                 bundleId: String,
                 version: String,
                 recordID: UUID? = nil,
                 displayName: String? = nil) {
        install(Request(metadata: SignedAppMetadata(ipaURL: ipa,
                                                    bundleIdentifier: bundleId,
                                                    version: version,
                                                    displayName: displayName ?? ipa.deletingPathExtension().lastPathComponent),
                        recordID: recordID))
    }

    func retry() {
        guard let request = lastRequest else { return }
        install(request)
    }

    /// Switches to the next available transport after a failure.
    func retryWithFallback() {
        guard let request = lastRequest else { return }
        let candidates = availability(for: request.metadata)
        guard let next = InstallationBackendSelection.fallbacks(after: method, candidates: candidates).first else {
            statusMessage = "No alternative installation method is available."
            return
        }
        method = next
        install(request)
    }

    func cancel() {
        guard activeToken != nil else { return }
        backends.forEach { $0.cancel() }
        activeToken = nil
        apply(InstallationProgress(phase: .cancelled, message: "Install cancelled."))
    }

    private func install(_ request: Request) {
        guard activeToken == nil else {
            statusMessage = "An installation is already running."
            return
        }

        lastRequest = request
        lastError = nil
        lastReceipt = nil
        fallbackMethods = []
        phase = .checkingEnvironment
        statusMessage = "Checking installation methods…"
        if let recordID = request.recordID {
            post(.installing, recordID: recordID)
        }

        let token = UUID()
        activeToken = token

        Task { [weak self] in
            guard let self else { return }
            defer { if self.activeToken == token { self.activeToken = nil } }

            let candidates = self.availability(for: request.metadata)
            switch InstallationBackendSelection.resolve(preferred: self.method, candidates: candidates) {
            case .failure(let error):
                self.fail(error, request: request)

            case .success(let method):
                guard let backend = self.backends.first(where: { $0.method == method }) else {
                    self.fail(.backendUnavailable("\(method.displayName) is not available in this build."), request: request)
                    return
                }
                self.fallbackMethods = InstallationBackendSelection.fallbacks(after: method, candidates: candidates)
                do {
                    let receipt = try await backend.install(request.metadata) { [weak self] progress in
                        self?.apply(progress)
                    }
                    self.finish(receipt, request: request)
                } catch is CancellationError {
                    self.apply(InstallationProgress(phase: .cancelled, message: "Install cancelled."))
                } catch let error as DeviceInstallError {
                    self.fail(error, request: request)
                } catch {
                    self.fail(.installRejected(error.localizedDescription), request: request)
                }
            }
        }
    }

    // MARK: - State

    private func apply(_ progress: InstallationProgress) {
        phase = progress.phase
        statusMessage = progress.message
    }

    private func finish(_ receipt: InstallationReceipt, request: Request) {
        lastReceipt = receipt
        lastError = nil
        phase = receipt.outcome == .installed ? .completed : .delivered
        statusMessage = receipt.detail ?? "Handed to iOS."
        if let recordID = request.recordID {
            post(Self.libraryState(for: receipt.outcome), recordID: recordID)
        }
    }

    private func fail(_ error: DeviceInstallError, request: Request) {
        lastError = error
        let message = error.localizedDescription
        phase = .failed(message)
        statusMessage = message
        if let recordID = request.recordID {
            post(.failed, recordID: recordID)
        }
    }

    /// Honest library mapping: only a device-confirmed install may read
    /// `installed`; a handoff to iOS reads `delivered`.
    static func libraryState(for outcome: InstallationOutcome) -> SigningRecord.InstallState {
        switch outcome {
        case .installed: return .installed
        case .deliveredToSystem: return .delivered
        }
    }

    private func post(_ state: SigningRecord.InstallState, recordID: UUID) {
        NotificationCenter.default.post(name: .forgeInstallState, object: nil,
                                        userInfo: ["recordID": recordID, "state": state.rawValue])
    }
}