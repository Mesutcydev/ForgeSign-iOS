#if canImport(IDevice)
import Foundation
import IDevice

/// The only code in ForgeSign that talks to a device.
///
/// Flow (mirrors upstream `ffi/examples/ipa_installer.c`):
///
///   Keychain pairing bytes → idevice_pairing_file_from_bytes
///     → idevice_tcp_provider_new (tunnel host:port, pairing file consumed)
///       → afc_client_connect            … stage to /PublicStaging/<name>
///         → installation_proxy_connect  … install / upgrade (+ progress)
///
/// Ownership: every handle is owned by this object, guarded by `lock`, and
/// released in `closeSession()`. The provider consumes the pairing file handle,
/// so that handle is never freed here.
///
/// The C API's handle types are opaque structs, so Swift sees them as
/// `OpaquePointer`. Every FFI call is blocking, so it runs in a detached task —
/// the main actor is never blocked by a transfer or an installation.
final class IDeviceTransport: DeviceTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: OpaquePointer?
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var afc: OpaquePointer?
    private var installer: OpaquePointer?

    /// Called when an RSD remote-pairing file is updated in place (fresh
    /// pair-setup ran); the owner persists the new payload so the next session
    /// pair-verifies instead of re-pairing. Guarded by `lock` like the handles.
    private var persistUpdatedRemotePairingPayload: (@Sendable (DevicePairingRecord, Data) -> Void)?

    /// The default transport wires persistence through the Keychain store.
    convenience init(persistUpdatedPayload: @escaping @Sendable (DevicePairingRecord, Data) -> Void) {
        self.init()
        lock.lock()
        persistUpdatedRemotePairingPayload = persistUpdatedPayload
        lock.unlock()
    }

    /// idevice only stages/installs what lives in the AFC jail's staging folder.
    static let stagingDirectory = "/PublicStaging"
    private static let chunkSize = 1 << 20

    var isAvailable: Bool { true }
    var unavailableReason: String { "" }

    // MARK: - Session

    func openSession(pairing: DevicePairingRecord, tunnel: DeviceTunnelEndpoint) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try openSessionSync(pairing: pairing, tunnel: tunnel)
        }.value
    }

    func closeSession() async {
        await Task.detached(priority: .utility) { [self] in
            closeSessionSync()
        }.value
    }

    private func openSessionSync(pairing: DevicePairingRecord, tunnel: DeviceTunnelEndpoint) throws {
        closeSessionSync()

        if pairing.kind == .remotePairing {
            // AltStore 2.x / SideStore `ALTPairingFile`: connect via the RSD
            // remote-pairing tunnel. The pairing file is borrowed and may be
            // updated in place on a fresh pair-setup, so persist it after use.
            guard let port = tunnel.port else {
                throw DeviceTransportError.connectionFailed("The tunnel endpoint has no port.")
            }
            var address = try Self.address(host: tunnel.host, port: port)

            var rpFile: OpaquePointer?
            let parseError = pairing.payload.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress,
                                           UInt(buffer.count),
                                           &rpFile)
            }
            if let error = Self.consume(parseError) { throw error }
            guard let rpFile else {
                throw DeviceTransportError.pairingRejected("The remote-pairing record could not be read.")
            }
            defer { rp_pairing_file_free(rpFile) }

            var newAdapter: OpaquePointer?
            var newHandshake: OpaquePointer?
            let host = "ForgeSign"
            let tunnelError = host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        tunnel_create_rppairing(sockaddrPointer,
                                                socklen_t(MemoryLayout<sockaddr_in>.size),
                                                hostPointer,
                                                rpFile,
                                                nil, nil,
                                                &newAdapter,
                                                &newHandshake)
                    }
                }
            }
            if let error = Self.consume(tunnelError) {
                if let newAdapter { adapter_free(newAdapter) }
                if let newHandshake { rsd_handshake_free(newHandshake) }
                throw error
            }
            guard let newAdapter, let newHandshake else {
                throw DeviceTransportError.connectionFailed("The remote-pairing tunnel could not be created.")
            }
            lock.lock()
            adapter = newAdapter
            handshake = newHandshake
            lock.unlock()

            // Remote-pairing records may be updated in place (fresh
            // pair-setup); persist the updated payload so next time it
            // pair-verifies instead of re-pairing.
            var updatedData: UnsafeMutablePointer<UInt8>?
            var updatedLength = 0
            if Self.consume(rp_pairing_file_to_bytes(rpFile, &updatedData, &updatedLength)) == nil,
               let updatedData, updatedLength > 0 {
                let updated = Data(bytes: updatedData, count: updatedLength)
                idevice_data_free(updatedData, UInt(updatedLength))
                lock.lock()
                let persist = persistUpdatedRemotePairingPayload
                lock.unlock()
                persist?(pairing, updated)
            }
            try connectServices()
            return
        }

        guard let port = tunnel.port else {
            throw DeviceTransportError.connectionFailed("The tunnel endpoint has no port.")
        }

        var pairingFile: OpaquePointer?
        let pairingError = pairing.payload.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            idevice_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress,
                                            UInt(buffer.count),
                                            &pairingFile)
        }
        if let error = Self.consume(pairingError) { throw error }
        guard let pairingFile else {
            throw DeviceTransportError.pairingRejected("The stored pairing record could not be read.")
        }

        var address = try Self.address(host: tunnel.host, port: port)
        var newProvider: OpaquePointer?
        let providerError = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                idevice_tcp_provider_new(sockaddrPointer, pairingFile, "ForgeSign", &newProvider)
            }
        }
        if let error = Self.consume(providerError) {
            // The provider did not take ownership, so release the pairing file.
            idevice_pairing_file_free(pairingFile)
            throw error
        }
        guard let newProvider else {
            idevice_pairing_file_free(pairingFile)
            throw DeviceTransportError.connectionFailed("The device provider could not be created.")
        }
        lock.lock()
        provider = newProvider
        lock.unlock()

        do {
            try connectServices()
        } catch {
            closeSessionSync()
            throw error
        }
    }

    /// Connects AFC + InstallationProxy over whichever session flavor is open.
    private func connectServices() throws {
        lock.lock()
        let currentAdapter = adapter
        let currentHandshake = handshake
        let currentProvider = provider
        lock.unlock()

        var newAFC: OpaquePointer?
        var newInstaller: OpaquePointer?
        if let currentAdapter, let currentHandshake {
            if let error = Self.consume(afc_client_connect_rsd(currentAdapter, currentHandshake, &newAFC)) {
                throw error
            }
            if let error = Self.consume(installation_proxy_connect_rsd(currentAdapter, currentHandshake, &newInstaller)) {
                if let newAFC { afc_client_free(newAFC) }
                throw error
            }
        } else if let currentProvider {
            if let error = Self.consume(afc_client_connect(currentProvider, &newAFC)) {
                throw error
            }
            if let error = Self.consume(installation_proxy_connect(currentProvider, &newInstaller)) {
                if let newAFC { afc_client_free(newAFC) }
                throw error
            }
        } else {
            throw DeviceTransportError.serviceUnavailable("No device session is open.")
        }
        guard let newAFC, let newInstaller else {
            if let newAFC { afc_client_free(newAFC) }
            throw DeviceTransportError.serviceUnavailable("The device installation services are unavailable.")
        }

        lock.lock()
        afc = newAFC
        installer = newInstaller
        lock.unlock()
    }

    private func closeSessionSync() {
        lock.lock()
        let installer = self.installer
        let afc = self.afc
        let provider = self.provider
        self.installer = nil
        self.afc = nil
        self.provider = nil
        lock.unlock()

        if let installer { installation_proxy_client_free(installer) }
        if let afc { afc_client_free(afc) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if let provider { idevice_provider_free(provider) }
    }

    // MARK: - Lookup

    func installedApp(bundleIdentifier: String) async throws -> InstalledAppRecord? {
        try await Task.detached(priority: .userInitiated) { [self] in
            try installedAppSync(bundleIdentifier: bundleIdentifier)
        }.value
    }

    private func installedAppSync(bundleIdentifier: String) throws -> InstalledAppRecord? {
        guard let installer else {
            throw DeviceTransportError.serviceUnavailable("No device session is open.")
        }

        var out: UnsafeMutableRawPointer?
        var count = 0
        let error = bundleIdentifier.withCString { pointer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let identifiers: [UnsafePointer<CChar>?] = [pointer]
            return identifiers.withUnsafeBufferPointer { buffer in
                installation_proxy_get_apps(installer, nil, buffer.baseAddress, 1, &out, &count)
            }
        }
        if let mapped = Self.consume(error) { throw mapped }

        if let out, count > 0 {
            let plists = out.assumingMemoryBound(to: plist_t?.self)
            for index in 0..<count {
                if let plist = plists[index] { plist_free(plist) }
            }
            free(out)
        }

        // The plist payload is not parsed yet; presence in the user app list is
        // what decides install vs upgrade.
        return count > 0 ? InstalledAppRecord(bundleIdentifier: bundleIdentifier, version: nil, name: nil) : nil
    }

    // MARK: - Staging

    func stage(package: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            try stageSync(package: package, onProgress: onProgress)
        }.value
    }

    private func stageSync(package: URL, onProgress: @escaping @Sendable (Double) -> Void) throws -> String {
        guard let afc else {
            throw DeviceTransportError.serviceUnavailable("No device session is open.")
        }
        let destination = "\(Self.stagingDirectory)/\(package.lastPathComponent)"

        // The directory normally exists; a failure here is not fatal.
        if let error = afc_make_directory(afc, Self.stagingDirectory) { idevice_error_free(error) }
        _ = Self.consume(afc_remove_path(afc, destination))

        var handle: OpaquePointer?
        if let error = Self.consume(afc_file_open(afc, destination, AfcWrOnly, &handle)) {
            throw error
        }
        guard let handle else {
            throw DeviceTransportError.stagingFailed("The staging path could not be opened.")
        }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: package)
        } catch {
            _ = Self.consume(afc_file_close(handle))
            throw DeviceTransportError.stagingFailed("The signed IPA could not be read.")
        }
        defer { try? input.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? Int64) ?? 0
        var written: Int64 = 0

        do {
            while true {
                let chunk = try input.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                let writeError = chunk.withUnsafeBytes { buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    afc_file_write(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
                }
                if let mapped = Self.consume(writeError) { throw mapped }
                written += Int64(chunk.count)
                if total > 0 { onProgress(min(1, Double(written) / Double(total))) }
            }
        } catch {
            _ = Self.consume(afc_file_close(handle))
            throw error
        }

        if let error = Self.consume(afc_file_close(handle)) { throw error }
        return destination
    }

    func removeStagedPackage(atPath: String) async {
        await Task.detached(priority: .utility) { [self] in
            removeStagedPackageSync(atPath: atPath)
        }.value
    }

    private func removeStagedPackageSync(atPath: String) {
        lock.lock()
        let afc = self.afc
        lock.unlock()
        guard let afc else { return }
        _ = Self.consume(afc_remove_path(afc, atPath))
    }

    // MARK: - Install

    func installStagedPackage(atPath: String,
                              bundleIdentifier: String,
                              upgrade: Bool,
                              onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try installSync(atPath: atPath, upgrade: upgrade, onProgress: onProgress)
        }.value
    }

    private func installSync(atPath: String,
                             upgrade: Bool,
                             onProgress: @escaping @Sendable (Double) -> Void) throws {
        guard let installer else {
            throw DeviceTransportError.serviceUnavailable("No device session is open.")
        }
        let box = ProgressBox(onProgress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        let callback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { rawProgress, context in
            guard let context else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
            box.report(min(1, Double(rawProgress) / 100))
        }

        let error = upgrade
            ? installation_proxy_upgrade_with_callback(installer, atPath, nil, callback, context)
            : installation_proxy_install_with_callback(installer, atPath, nil, callback, context)

        if let mapped = Self.consume(error) {
            throw upgrade
                ? DeviceTransportError.upgradeFailed(mapped.userFacingReason)
                : DeviceTransportError.installFailed(mapped.userFacingReason)
        }
    }

    // MARK: - FFI plumbing

    /// Frees an FFI error and turns it into a typed transport error. Returns nil
    /// when the call succeeded (the error pointer is null).
    private static func consume(_ error: UnsafeMutablePointer<IdeviceFfiError>?) -> DeviceTransportError? {
        guard let error else { return nil }
        let code = error.pointee.code
        let message = error.pointee.message.map { String(cString: $0) } ?? "error \(code)"
        idevice_error_free(error)
        return classify(message)
    }

    static func classify(_ message: String) -> DeviceTransportError {
        let text = message.lowercased()
        if text.contains("pair") { return .pairingRejected(message) }
        if text.contains("connect") || text.contains("socket") || text.contains("timed out")
            || text.contains("refused") || text.contains("unreachable") {
            return .connectionFailed(message)
        }
        if text.contains("afc") || text.contains("staging") || text.contains("write")
            || text.contains("open") || text.contains("disk") {
            return .stagingFailed(message)
        }
        if text.contains("upgrade") { return .upgradeFailed(message) }
        return .installFailed(message)
    }

    private static func address(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw DeviceTransportError.connectionFailed("The tunnel address \(host) is not a usable IPv4 address.")
        }
        return address
    }
}

/// Carries a Swift progress closure into the C callback context.
private final class ProgressBox: @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func report(_ value: Double) {
        report(value)
    }
}
#endif