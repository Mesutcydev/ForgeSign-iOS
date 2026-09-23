import Foundation
import Network
import UIKit

/// Real reachability probe for tunnel candidates. Plain TCP: the VPN route is
/// what makes the device's own lockdown port answer, so no IP is assumed.
struct NetworkPortProber: DevicePortProbing {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "com.forgesign.tunnel.probe", qos: .utility)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ProbeGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.resume(true) { connection.cancel() }
                case .failed, .cancelled:
                    _ = gate.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.resume(false) { connection.cancel() }
            }
        }
    }
}

/// Resumes exactly once: NWConnection state changes and the timeout can race.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// Returns true when this call was the one that resumed (so the caller can
    /// cancel its connection exactly once).
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(returning: value)
        return true
    }
}

/// Owns the pairing + health state shown in the Device Installation section.
/// Everything here is storage and inspection; no transfer or installation runs
/// until the direct transport lands (Phase 3).
@MainActor
final class DeviceInstallationModel: ObservableObject {
    @Published private(set) var records: [DevicePairingRecord] = []
    @Published private(set) var pairing: DevicePairingStatus = .empty
    @Published private(set) var health: DeviceInstallHealth?
    @Published private(set) var tunnel: DeviceTunnelEndpoint?
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    /// Result of the last real device-service probe (nil until one ran).
    @Published private(set) var serviceProbe: DeviceServiceProbeResult?

    private var hasProbedTunnel = false
    private var lastMethods: [InstallationMethod] = []
    private var lastExpectedUDID: String?
    private let store: DevicePairingStoring
    private let prober: DevicePortProbing

    init(store: DevicePairingStoring = KeychainDevicePairingStore(),
         prober: DevicePortProbing = NetworkPortProber()) {
        self.store = store
        self.prober = prober
    }

    var hasRecord: Bool { !records.isEmpty }

    /// Lets the UI surface a validation message without importing anything.
    func note(_ message: String) {
        self.message = message
    }

    // MARK: - Pairing

    func refresh(availableMethods: [InstallationMethod],
                 expectedUDID: String?,
                 tunnelProbed: Bool? = nil,
                 osVersion: String = UIDevice.current.systemVersion) {
        lastMethods = availableMethods
        lastExpectedUDID = expectedUDID
        records = store.records()
        pairing = DevicePairingValidator.status(records: records,
                                                expectedUDID: expectedUDID,
                                                connectionReachable: serviceProbe?.state == .ok,
                                                lastValidated: nil)
        health = DeviceInstallHealthService.makeHealth(pairing: pairing,
                                                       tunnel: tunnel,
                                                       tunnelProbed: tunnelProbed ?? hasProbedTunnel,
                                                       availableMethods: availableMethods,
                                                       osVersion: osVersion,
                                                       serviceProbe: serviceProbe)
    }

    /// Re-derives state after a store change, reusing the last known context.
    private func refreshWithLastContext(osVersion: String = UIDevice.current.systemVersion) {
        refresh(availableMethods: lastMethods, expectedUDID: lastExpectedUDID, osVersion: osVersion)
    }

    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch DevicePairingRecord.parse(data: data, filenameHint: url.lastPathComponent) {
            case .success(let record):
                try store.save(record)
                message = "Pairing record stored for \(SanitizedDiagnostics.mask(udid: record.udid))."
            case .failure(let error):
                message = error.localizedDescription
            }
        } catch {
            message = "The pairing file could not be read."
        }
        refreshWithLastContext()
    }

    func remove(_ record: DevicePairingRecord) {
        store.remove(udid: record.udid)
        message = "Pairing record removed."
        refreshWithLastContext()
    }

    func removeAll() {
        records.forEach { store.remove(udid: $0.udid) }
        message = "All pairing records removed."
        refreshWithLastContext()
    }

    // MARK: - Checks

    func runFullCheck(availableMethods: [InstallationMethod],
                      expectedUDID: String?,
                      customHost: String? = nil) async {
        guard !isChecking else { return }
        isChecking = true
        message = nil
        defer { isChecking = false }

        let endpoints = DeviceTunnelCandidates.endpoints(customHost: customHost)
        tunnel = await DeviceTunnelProbe.firstReachable(endpoints: endpoints, prober: prober)
        hasProbedTunnel = true
        DeviceTunnelLocator.shared.update(tunnel)

        // A remote-pairing record does not need the VPN tunnel: the device's
        // own remote-pairing listener is the endpoint. Probe it for real.
        if let record = records.first, record.kind == .remotePairing {
            serviceProbe = await DeviceServiceProber.shared.probeDeviceServices(pairing: record)
        }

        refresh(availableMethods: availableMethods, expectedUDID: expectedUDID)
        if tunnel == nil, serviceProbe?.state != .ok {
            message = "No tunnel endpoint answered and no device was discovered on the local network."
        }
    }

    func diagnosticsReport(availableMethods: [InstallationMethod],
                           expectedUDID: String?,
                           anisetteSource: String,
                           appVersion: String = DeviceInstallationModel.appVersion,
                           osVersion: String = UIDevice.current.systemVersion) -> String {
        SanitizedDiagnostics.report(health: health ?? DeviceInstallHealthService.makeHealth(
                                        pairing: pairing,
                                        tunnel: tunnel,
                                        tunnelProbed: hasProbedTunnel,
                                        availableMethods: availableMethods,
                                        osVersion: osVersion),
                                    pairing: pairing,
                                    records: records,
                                    availableMethods: availableMethods,
                                    appVersion: appVersion,
                                    osVersion: osVersion,
                                    anisetteSource: anisetteSource)
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}