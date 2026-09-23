import Foundation

// MARK: - Installation model
//
// Signing ends at a verified signed IPA. Everything after that is installation,
// and installation is deliberately a separate, swappable layer:
//
//   Verified signed IPA → InstallCoordinator → IPAInstallationBackend
//                                              ├─ OTAInstallationBackend      (implemented)
//                                              ├─ Direct device               (Phase 3)
//                                              └─ Remote AltServer            (Phase 4)
//
// The OTA backend wraps the existing loopback-server + itms-services flow
// unchanged. New backends are additive and must not re-sign the IPA.

/// Everything an installation backend needs about an already-signed package.
struct SignedAppMetadata: Equatable, Sendable {
    let ipaURL: URL
    let bundleIdentifier: String
    let version: String
    let displayName: String
}

/// Why a backend can or cannot run right now.
enum InstallationBackendAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case requiresPairing
    case requiresVPN
    case requiresWiFi
    case requiresRemoteServer
    case unsupportedOS

    var isAvailable: Bool { self == .available }

    var explanation: String {
        switch self {
        case .available: return "Available"
        case .unavailable(let reason): return reason
        case .requiresPairing: return "Needs a device pairing record."
        case .requiresVPN: return "Needs the local device tunnel (LocalDevVPN) to be connected."
        case .requiresWiFi: return "Connect to Wi-Fi; cellular is not enough."
        case .requiresRemoteServer: return "Needs a reachable remote AltServer."
        case .unsupportedOS: return "Not supported on this iOS version."
        }
    }
}

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

/// How an installation finished. `deliveredToSystem` is the honest outcome for
/// transports that hand the package to iOS and cannot observe the final result.
enum InstallationOutcome: String, Equatable, Sendable {
    case deliveredToSystem
    case installed
}

struct InstallationReceipt: Equatable, Sendable {
    let method: InstallationMethod
    let bundleIdentifier: String
    let outcome: InstallationOutcome
    let completedAt: Date
    let detail: String?

    init(method: InstallationMethod,
         bundleIdentifier: String,
         outcome: InstallationOutcome,
         completedAt: Date = Date(),
         detail: String? = nil) {
        self.method = method
        self.bundleIdentifier = bundleIdentifier
        self.outcome = outcome
        self.completedAt = completedAt
        self.detail = detail
    }
}

// MARK: - Methods and selection

enum InstallationMethod: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case directDevice
    case remoteAltServer
    case ota

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .directDevice: return "Direct Device"
        case .remoteAltServer: return "Remote AltServer"
        case .ota: return "OTA"
        }
    }

    /// Most private and reliable first: a paired local device, then a remote
    /// AltServer, then the OTA manifest handoff.
    static let preferenceOrder: [InstallationMethod] = [.directDevice, .remoteAltServer, .ota]
}

enum InstallationBackendSelection {
    struct Candidate: Equatable, Sendable {
        let method: InstallationMethod
        let availability: InstallationBackendAvailability
    }

    /// Resolves the requested method against what is actually usable.
    static func resolve(preferred: InstallationMethod,
                        candidates: [Candidate]) -> Result<InstallationMethod, DeviceInstallError> {
        guard !candidates.isEmpty else {
            return .failure(.backendUnavailable("No installation method is available in this build."))
        }
        if preferred != .automatic {
            guard let candidate = candidates.first(where: { $0.method == preferred }) else {
                return .failure(.backendUnavailable("\(preferred.displayName) is not available in this build."))
            }
            guard candidate.availability.isAvailable else {
                return .failure(.backendUnavailable("\(preferred.displayName): \(candidate.availability.explanation)"))
            }
            return .success(preferred)
        }
        for method in InstallationMethod.preferenceOrder {
            if let candidate = candidates.first(where: { $0.method == method }), candidate.availability.isAvailable {
                return .success(method)
            }
        }
        return .failure(.backendUnavailable(candidates.map { "\($0.method.displayName): \($0.availability.explanation)" }
            .joined(separator: " · ")))
    }

    /// Methods the user can still try after one failed, in preference order.
    static func fallbacks(after method: InstallationMethod,
                          candidates: [Candidate]) -> [InstallationMethod] {
        InstallationMethod.preferenceOrder.filter { candidate in
            candidate != method && candidates.contains { $0.method == candidate && $0.availability.isAvailable }
        }
    }
}

// MARK: - Errors

enum DeviceInstallError: LocalizedError, Equatable, Sendable {
    case pairingMissing
    case pairingInvalid
    case pairingDeviceMismatch
    case tunnelUnavailable
    case deviceUnavailable
    case serviceDiscoveryFailed
    case stagingFailed
    case transferFailed
    case installRejected(String)
    case upgradeRejected(String)
    case connectionLost
    case remoteServerUnavailable
    case remoteServerIncompatible
    case unsupportedOS
    case backendUnavailable(String)
    case unverifiedPackage
    case cancelled

    var errorDescription: String? {
        switch self {
        case .pairingMissing:
            return "This installation method needs a device pairing record. Import one in Settings, or use OTA."
        case .pairingInvalid:
            return "The device pairing record is no longer valid. Pair again, import a new one, or use OTA."
        case .pairingDeviceMismatch:
            return "The pairing record belongs to a different device."
        case .tunnelUnavailable:
            return "The local device tunnel is not reachable. Start LocalDevVPN, then try again."
        case .deviceUnavailable:
            return "This iPhone is not reachable right now."
        case .serviceDiscoveryFailed:
            return "The device services could not be discovered."
        case .stagingFailed:
            return "The signed IPA could not be staged for installation."
        case .transferFailed:
            return "The package transfer did not finish."
        case .installRejected(let reason):
            return reason.isEmpty ? "iOS rejected the installation." : "iOS rejected the installation: \(reason)"
        case .upgradeRejected(let reason):
            return reason.isEmpty ? "iOS rejected the upgrade." : "iOS rejected the upgrade: \(reason)"
        case .connectionLost:
            return "The connection to the device was lost during installation."
        case .remoteServerUnavailable:
            return "The remote AltServer is not reachable."
        case .remoteServerIncompatible:
            return "The remote server speaks an unsupported protocol version."
        case .unsupportedOS:
            return "This installation method is not supported on this iOS version."
        case .backendUnavailable(let reason):
            return reason
        case .unverifiedPackage:
            return "The signed IPA failed verification, so it was not installed."
        case .cancelled:
            return "Installation cancelled."
        }
    }
}

// MARK: - Feature flags

/// Experimental pathways stay behind flags until they are proven on a device.
enum FeatureFlags {
    /// Direct paired-device installation (idevice transport). Enabled for
    /// hardware validation; the OTA backend stays the default fallback.
    static let directDeviceInstall = true
    static let remoteAltServerInstall = false
    static let autoRefresh = false
    static let iOS27OnDevicePairing = false
}

// MARK: - Backend protocol

@MainActor
protocol IPAInstallationBackend: AnyObject {
    var method: InstallationMethod { get }
    var displayName: String { get }

    /// Cheap, synchronous readiness check for this build and this package.
    func availability(for app: SignedAppMetadata) -> InstallationBackendAvailability

    /// Runs the installation. Returns once the package has been handed off;
    /// device backends report `.installed`, transports that cannot observe the
    /// final result report `.deliveredToSystem`.
    func install(_ app: SignedAppMetadata,
                 progress: @escaping (InstallationProgress) -> Void) async throws -> InstallationReceipt

    func cancel()
}
