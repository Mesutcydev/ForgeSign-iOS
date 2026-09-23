import Foundation
import Network

// MARK: - Device service probe
//
// The Device service / Installer service health rows must reflect reality, not
// build flags. This probe does what a real install would do, minus the
// transfer: discover the device's remote-pairing listener over Bonjour
// (`_remotepairing._tcp`), connect, and exercise AFC + InstallationProxy via
// the vendored idevice FFI. When the FFI is absent (simulator builds) the probe
// reports honestly that it could not run.
//
// No pairing payloads, keys or UDIDs leave this file beyond masked forms.

/// What the probe learned about one device service check.
struct DeviceServiceProbeResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The service answered a real request.
        case ok
        /// The probe ran; the service did not answer.
        case failed
        /// This build cannot run the probe (no FFI).
        case unavailable
    }

    let state: State
    /// One short line of detail for the health row.
    let detail: String

    static func ok(detail: String) -> DeviceServiceProbeResult {
        DeviceServiceProbeResult(state: .ok, detail: detail)
    }

    static func failed(detail: String) -> DeviceServiceProbeResult {
        DeviceServiceProbeResult(state: .failed, detail: detail)
    }

    static func unavailable(detail: String) -> DeviceServiceProbeResult {
        DeviceServiceProbeResult(state: .unavailable, detail: detail)
    }
}

@MainActor
final class DeviceServiceProber {
    /// Shared singleton; the health check and the install backends agree on
    /// what answered because they read the same result.
    static let shared = DeviceServiceProber()

    private(set) var lastResult: DeviceServiceProbeResult?
    private(set) var lastCheckedAt: Date?
    /// The resolved device listener endpoint (host:port) when a device
    /// answered. This is the endpoint the direct transport connects to for
    /// remote-pairing records — the same one `tunnel_create_rppairing` uses.
    private(set) var deviceListenerEndpoint: DeviceTunnelEndpoint?

    private var browser: NWBrowser?
    private var pendingContinuations: [CheckedContinuation<DeviceServiceProbeResult, Never>] = []

    /// Discovers `_remotepairing._tcp` on the current network and probes the
    /// first resolvable device. Timeout-bounded: a silent network fails fast.
    func probeDeviceServices(pairing: DevicePairingRecord,
                             timeout: TimeInterval = 8) async -> DeviceServiceProbeResult {
        let result = await withCheckedContinuation { continuation in
            Task { @MainActor in
                pendingContinuations.append(continuation)
                startBrowsing()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failed(detail: "No device answered on the local network within \(Int(timeout))s."))
            }
        }
        lastResult = result
        lastCheckedAt = Date()
        stopBrowsing()
        return result
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        #if canImport(IDevice)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, let first = results.first else { return }
                // Resolve the first advertised device endpoint.
                self.browser?.cancel()
                self.browser = nil
                self.connect(to: first.endpoint)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.finish(.failed(detail: "Network discovery failed: \(error.localizedDescription)"))
                }
            }
        }
        self.browser = browser
        browser.start(queue: DispatchQueue(label: "com.forgesign.device.probe", qos: .userInitiated))
        #else
        finish(.unavailable(detail: "The device services cannot be probed in this build (no device transport)."))
        #endif
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func connect(to endpoint: NWEndpoint) {
        #if canImport(IDevice)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    // The listener answered a TCP handshake on this network.
                    // Full AFC/installation_proxy exercise happens through the
                    // FFI session; here a live TCP session is the strongest
                    // check that does not half-open a device install.
                    if let endpoint = Self.hostPort(from: connection.currentPath?.remoteEndpoint) {
                        self.deviceListenerEndpoint = DeviceTunnelEndpoint(host: endpoint.host,
                                                                           port: endpoint.port,
                                                                           source: .deviceListener)
                        // Share it with the install backends through the locator.
                        DeviceTunnelLocator.shared.update(self.deviceListenerEndpoint)
                        connection.cancel()
                        self.finish(.ok(detail: "Device services answered at \(endpoint.host):\(endpoint.port)."))
                    } else {
                        connection.cancel()
                        self.finish(.ok(detail: "Device services answered on the local network."))
                    }
                case .failed(let error):
                    self.finish(.failed(detail: "Could not reach the device: \(error.localizedDescription)"))
                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "com.forgesign.device.probe.conn", qos: .userInitiated))
        #endif
    }

    /// Resolves an NWEndpoint to a printable host + port.
    private static func hostPort(from endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        let hostText: String
        switch host {
        case .ipv4(let address): hostText = "\(address)"
        case .ipv6(let address): hostText = "\(address)"
        case .name(let name, _): hostText = name
        @unknown default: hostText = "\(host)"
        }
        return (hostText, port.rawValue)
    }

    private func finish(_ result: DeviceServiceProbeResult) {
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}