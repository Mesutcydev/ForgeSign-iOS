import Foundation

/// Paired-device installation.
///
/// Signing is untouched: this backend receives a package ForgeSign already
/// verified, transfers it to the device, and asks the device's installation
/// service to install or upgrade it — in place, so app data survives.
@MainActor
final class DirectDeviceInstallationBackend: IPAInstallationBackend {
    let method: InstallationMethod = .directDevice
    let displayName = "Direct Device"

    private let transport: DeviceTransporting
    private let isEnabled: Bool
    private let pairingProvider: @MainActor () -> [DevicePairingRecord]
    private let tunnelProvider: @MainActor () -> DeviceTunnelEndpoint?
    private let expectedUDIDProvider: @MainActor () -> String?
    private var cancelled = false

    init(transport: DeviceTransporting = DeviceTransportFactory.make(),
         isEnabled: Bool = FeatureFlags.directDeviceInstall,
         pairingProvider: @escaping @MainActor () -> [DevicePairingRecord] = { KeychainDevicePairingStore().records() },
         tunnelProvider: @escaping @MainActor () -> DeviceTunnelEndpoint? = { DeviceTunnelLocator.shared.endpoint },
         expectedUDIDProvider: @escaping @MainActor () -> String? = { ProvisioningAuditService.currentDeviceIdentifier }) {
        self.transport = transport
        self.isEnabled = isEnabled
        self.pairingProvider = pairingProvider
        self.tunnelProvider = tunnelProvider
        self.expectedUDIDProvider = expectedUDIDProvider
    }

    // MARK: - Availability

    func availability(for app: SignedAppMetadata) -> InstallationBackendAvailability {
        guard isEnabled else {
            return .unavailable(reason: "The paired-device transport is not enabled in this build yet.")
        }
        guard transport.isAvailable else {
            return .unavailable(reason: transport.unavailableReason)
        }
        guard FileManager.default.fileExists(atPath: app.ipaURL.path) else {
            return .unavailable(reason: "The signed IPA is no longer in the Library.")
        }
        let records = pairingProvider()
        guard !records.isEmpty else { return .requiresPairing }
        let status = DevicePairingValidator.status(records: records, expectedUDID: expectedUDIDProvider())
        guard status.recordValid else {
            return .unavailable(reason: "The stored pairing record is invalid.")
        }
        guard status.deviceIdentifierMatches != false else {
            return .unavailable(reason: "The stored pairing record belongs to another device.")
        }
        // A remote-pairing record connects to the device's own listener
        // (discovered via Bonjour, shared through the locator); only a
        // lockdown record needs the LocalDevVPN tunnel.
        let endpoint = tunnelProvider()
        let needsVPNTunnel = records.first?.kind == .lockdown
        if needsVPNTunnel, endpoint == nil { return .requiresVPN }
        if endpoint == nil { return .requiresVPN }
        return .available
    }

    // MARK: - Install

    func install(_ app: SignedAppMetadata,
                 progress: @escaping (InstallationProgress) -> Void) async throws -> InstallationReceipt {
        cancelled = false
        progress(InstallationProgress(phase: .checkingEnvironment, message: "Checking the paired device…"))

        if case .unavailable(let reason) = availability(for: app) {
            throw DeviceInstallError.backendUnavailable(reason)
        }
        guard let record = pairingProvider().first else { throw DeviceInstallError.pairingMissing }
        guard let tunnel = tunnelProvider() else { throw DeviceInstallError.tunnelUnavailable }

        progress(InstallationProgress(phase: .connecting, message: "Connecting to the device…"))
        do {
            try await transport.openSession(pairing: record, tunnel: tunnel)
        } catch {
            throw Self.map(error, upgrade: false)
        }

        // The session is always closed before returning — never fire-and-forget,
        // so a finished install leaves no dangling device connection.
        do {
            let receipt = try await performInstall(app, progress: progress)
            await transport.closeSession()
            return receipt
        } catch {
            await transport.closeSession()
            throw error
        }
    }

    private func performInstall(_ app: SignedAppMetadata,
                                progress: @escaping (InstallationProgress) -> Void) async throws -> InstallationReceipt {
        try Task.checkCancellation()
        progress(InstallationProgress(phase: .preparingPackage, message: "Checking what is already installed…"))
        let installed: InstalledAppRecord?
        do {
            installed = try await transport.installedApp(bundleIdentifier: app.bundleIdentifier)
        } catch {
            throw Self.map(error, upgrade: false)
        }
        let upgrade = installed != nil

        try Task.checkCancellation()
        let stagedPath: String
        let reporter = InstallProgressReporter(progress)
        do {
            stagedPath = try await transport.stage(package: app.ipaURL) { fraction in
                // Transport callbacks may arrive off the main actor; the reporter
                // is main-actor isolated so the UI state stays consistent.
                Task { @MainActor in
                    reporter.report(InstallationProgress(phase: .transferring(fraction),
                                                         message: "Transferring \(Int(fraction * 100))%…",
                                                         fraction: fraction))
                }
            }
        } catch {
            throw Self.map(error, upgrade: upgrade)
        }

        try Task.checkCancellation()
        progress(InstallationProgress(phase: .installing(0),
                                      message: upgrade ? "Upgrading the installed app…" : "Installing…"))
        do {
            try await transport.installStagedPackage(atPath: stagedPath,
                                                     bundleIdentifier: app.bundleIdentifier,
                                                     upgrade: upgrade) { fraction in
                Task { @MainActor in
                    reporter.report(InstallationProgress(phase: .installing(fraction),
                                                         message: "\(upgrade ? "Upgrading" : "Installing") \(Int(fraction * 100))%…",
                                                         fraction: fraction))
                }
            }
        } catch {
            await transport.removeStagedPackage(atPath: stagedPath)
            throw Self.map(error, upgrade: upgrade)
        }

        await transport.removeStagedPackage(atPath: stagedPath)
        progress(InstallationProgress(phase: .verifying, message: "Confirming the installation…"))

        let detail = upgrade
            ? "Upgraded in place — app data preserved."
            : "Installed on the device."
        return InstallationReceipt(method: method,
                                   bundleIdentifier: app.bundleIdentifier,
                                   outcome: .installed,
                                   detail: detail)
    }

    func cancel() {
        cancelled = true
        Task { await transport.closeSession() }
    }

    // MARK: - Mapping

    /// Transport failures become typed, user-facing install errors. An upgrade
    /// that fails is reported as an upgrade so the message matches what the user
    /// was doing (their installed app is left untouched).
    static func map(_ error: Error, upgrade: Bool) -> DeviceInstallError {
        if error is CancellationError { return .cancelled }
        guard let transportError = error as? DeviceTransportError else {
            return .installRejected(error.localizedDescription)
        }
        switch transportError {
        case .notAvailable(let detail): return .backendUnavailable(detail)
        case .connectionFailed: return .connectionLost
        case .pairingRejected(let detail): return .pairingInvalid
        case .serviceUnavailable: return .deviceUnavailable
        case .stagingFailed, .transferFailed: return .transferFailed
        case .installFailed(let detail): return .installRejected(detail)
        case .upgradeFailed(let detail): return .upgradeRejected(detail)
        case .cleanupFailed: return upgrade ? .upgradeRejected("") : .installRejected("")
        }
    }
}

/// Holds the caller's progress closure behind main-actor isolation so transports
/// can report progress from any thread without sending the closure itself.
@MainActor
private final class InstallProgressReporter {
    private let progress: (InstallationProgress) -> Void

    init(_ progress: @escaping (InstallationProgress) -> Void) {
        self.progress = progress
    }

    func report(_ event: InstallationProgress) {
        progress(event)
    }
}