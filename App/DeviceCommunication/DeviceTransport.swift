import Foundation

// MARK: - Device transport
//
// The direct-install transport is deliberately split in two:
//
//   DirectDeviceInstallationBackend   orchestration (this layer, testable)
//        └── DeviceTransporting       the only thing that touches the device
//             └── IDeviceTransport     idevice FFI (compile-guarded)
//
// Everything except the FFI implementation is exercised by tests with a stub
// transport, so the control flow, error mapping, upgrade decision, cleanup and
// cancellation are already proven before any hardware is involved.

struct InstalledAppRecord: Equatable, Sendable {
    let bundleIdentifier: String
    let version: String?
    let name: String?
}

enum DeviceTransportError: Error, Equatable, Sendable {
    case notAvailable(String)
    case connectionFailed(String)
    case pairingRejected(String)
    case serviceUnavailable(String)
    case stagingFailed(String)
    case transferFailed(String)
    case installFailed(String)
    case upgradeFailed(String)
    case cleanupFailed(String)

    var userFacingReason: String {
        switch self {
        case .notAvailable(let detail): return detail
        case .connectionFailed(let detail): return "Could not connect to the device: \(detail)"
        case .pairingRejected(let detail): return "The device rejected the pairing record: \(detail)"
        case .serviceUnavailable(let detail): return "The device service is unavailable: \(detail)"
        case .stagingFailed(let detail): return "Staging failed: \(detail)"
        case .transferFailed(let detail): return "The package transfer failed: \(detail)"
        case .installFailed(let detail): return detail.isEmpty ? "iOS rejected the installation." : detail
        case .upgradeFailed(let detail): return detail.isEmpty ? "iOS rejected the upgrade." : detail
        case .cleanupFailed(let detail): return "Cleanup failed: \(detail)"
        }
    }
}

/// One session against one device. Implementations own their C handles and must
/// release them in `closeSession()`.
protocol DeviceTransporting: Sendable {
    /// False when this build has no transport (FFI missing) — with the reason.
    var isAvailable: Bool { get }
    var unavailableReason: String { get }

    func openSession(pairing: DevicePairingRecord, tunnel: DeviceTunnelEndpoint) async throws
    func closeSession() async

    /// Looks up an installed app so install vs upgrade can be decided honestly.
    func installedApp(bundleIdentifier: String) async throws -> InstalledAppRecord?

    /// Copies the signed IPA to the device's staging area. Returns the staged path.
    func stage(package: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String

    /// Installs or upgrades an already staged package. Progress is 0…1.
    func installStagedPackage(atPath: String,
                              bundleIdentifier: String,
                              upgrade: Bool,
                              onProgress: @escaping @Sendable (Double) -> Void) async throws

    /// Best-effort removal of a staged package (never the user's IPA).
    func removeStagedPackage(atPath: String) async
}

/// Where the current tunnel endpoint lives, shared by the health check and the
/// install backends. MainActor-isolated like the rest of the install layer.
@MainActor
final class DeviceTunnelLocator {
    static let shared = DeviceTunnelLocator()

    private(set) var endpoint: DeviceTunnelEndpoint?

    func update(_ endpoint: DeviceTunnelEndpoint?) {
        self.endpoint = endpoint
    }
}

/// Builds the real transport, or an "unavailable" stand-in when the vendored
/// idevice FFI is not linked into this build.
enum DeviceTransportFactory {
    static func make() -> DeviceTransporting {
        #if canImport(IDevice)
        return IDeviceTransport()
        #else
        return UnavailableDeviceTransport(
            reason: "This build has no device transport. Build the vendored idevice framework with scripts/build_idevice_xcframework.sh, then regenerate the project."
        )
        #endif
    }
}

/// Honest stand-in used when the FFI is missing: everything reports why.
struct UnavailableDeviceTransport: DeviceTransporting {
    let reason: String

    var isAvailable: Bool { false }
    var unavailableReason: String { reason }

    func openSession(pairing: DevicePairingRecord, tunnel: DeviceTunnelEndpoint) async throws {
        throw DeviceTransportError.notAvailable(reason)
    }

    func closeSession() async {}

    func installedApp(bundleIdentifier: String) async throws -> InstalledAppRecord? {
        throw DeviceTransportError.notAvailable(reason)
    }

    func stage(package: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        throw DeviceTransportError.notAvailable(reason)
    }

    func installStagedPackage(atPath: String,
                              bundleIdentifier: String,
                              upgrade: Bool,
                              onProgress: @escaping @Sendable (Double) -> Void) async throws {
        throw DeviceTransportError.notAvailable(reason)
    }

    func removeStagedPackage(atPath: String) async {}
}