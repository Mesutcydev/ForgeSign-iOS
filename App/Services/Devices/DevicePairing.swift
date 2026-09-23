import Foundation
import CryptoKit

// MARK: - Pairing records
//
// A pairing record is a credential: it lets a host talk to this device's
// lockdown services, so it is stored in the Keychain (ThisDeviceOnly) and never
// logged, shown, or included in diagnostics. Only non-secret metadata leaves
// the store.

enum DevicePairingError: LocalizedError, Sendable {
    case notAPairingRecord
    case missingField(String)
    case unusableUDID
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAPairingRecord:
            return "That file is not a device pairing record. Import a .mobiledevicepairing or .plist exported by AltStore, SideStore or idevice_pair."
        case .missingField(let field):
            return "The pairing record is missing “\(field)” and cannot be used."
        case .unusableUDID:
            return "The pairing record does not contain a usable device UDID."
        case .storageFailed(let detail):
            return detail.isEmpty
                ? "The pairing record could not be stored in the Keychain."
                : "The pairing record could not be stored: \(detail)"
        }
    }
}

/// Parsed, non-secret view of one pairing record plus its raw payload.
struct DevicePairingRecord: Identifiable, Equatable, Sendable {
    /// Lockdown (AltStore Classic / `idevice pair`) records carry
    /// HostID/HostPrivateKey/RootCertificate and a UDID.
    /// RSD remote-pairing records (AltStore 2.x / SideStore `ALTPairingFile`,
    /// `pairable_host`) carry only ed25519 `public_key`/`private_key`/
    /// `identifier` — no UDID by design; the device identity is discovered
    /// when a tunnel session runs.
    enum Kind: Equatable, Sendable {
        case lockdown
        case remotePairing

        var label: String {
            switch self {
            case .lockdown: return "lockdown"
            case .remotePairing: return "remote pairing"
            }
        }
    }

    let udid: String
    let hostID: String?
    let deviceCertificateFingerprint: String?
    let addedAt: Date
    let payload: Data
    let kind: Kind

    var id: String { udid }
    var byteCount: Int { payload.count }

    var displayName: String {
        kind == .remotePairing
            ? "Paired over remote pairing"
            : "Paired device \(SanitizedDiagnostics.mask(udid: udid))"
    }

    static func parse(data: Data, filenameHint: String? = nil, addedAt: Date = Date()) -> Result<DevicePairingRecord, DevicePairingError> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let record = plist as? [String: Any] else {
            return .failure(.notAPairingRecord)
        }

        // --- RSD remote-pairing record (AltStore 2.x / SideStore format) ---
        if let publicKey = record["public_key"] as? Data,
           let privateKey = record["private_key"] as? Data,
           !publicKey.isEmpty, !privateKey.isEmpty {
            let identifier = (record["identifier"] as? String) ?? "remote"
            return .success(DevicePairingRecord(udid: "rppairing-\(identifier)",
                                                hostID: nil,
                                                deviceCertificateFingerprint: nil,
                                                addedAt: addedAt,
                                                payload: data,
                                                kind: .remotePairing))
        }

        // --- Lockdown record (AltStore Classic / idevice pair) ---
        // AltStore/SideStore-style records carry the UDID inside; host-side
        // records written by `idevice pair` / pair_host carry it only in the
        // filename (…-<UDID>.mobiledevicepairing), so accept both.
        var udid = (record["UDID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if udid.isEmpty, let hint = filenameHint {
            // A dashed UDID contains '-', so tokenizing would destroy it: scan
            // for a complete UDID substring first (case preserved), then fall
            // back to bare tokens.
            if let scanned = DevicePairingRecord.scanForUDID(in: hint) {
                udid = scanned
            } else {
                let tokens = hint.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == " " })
                    .compactMap { String($0) }
                for token in tokens.reversed() {
                    if DevicePairingRecord.isPlausibleUDID(token) { udid = token; break }
                }
            }
        }
        guard !udid.isEmpty else {
            return .failure(.missingField("UDID"))
        }
        guard DevicePairingRecord.isPlausibleUDID(udid) else { return .failure(.unusableUDID) }

        // Host-side records legitimately omit the device-side fields; what we
        // truly require is the host private key + root cert that let a host
        // speak lockdown to this device.
        for field in ["HostID", "HostPrivateKey", "RootCertificate"] {
            guard let value = record[field] else { return .failure(.missingField(field)) }
            if let text = value as? String, text.isEmpty { return .failure(.missingField(field)) }
            if let blob = value as? Data, blob.isEmpty { return .failure(.missingField(field)) }
        }

        let fingerprint = (record["DeviceCertificate"] as? Data).map { certificate in
            SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined().prefix(16)
        }.map(String.init)

        return .success(DevicePairingRecord(udid: udid,
                                            hostID: record["HostID"] as? String,
                                            deviceCertificateFingerprint: fingerprint,
                                            addedAt: addedAt,
                                            payload: data,
                                            kind: .lockdown))
    }

    /// 40-character hex UDIDs and the newer dashed form (00008110-000E34240250201E).
    static func isPlausibleUDID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if trimmed.count == 40, trimmed.unicodeScalars.allSatisfy({ hex.contains($0) }) { return true }
        let parts = trimmed.split(separator: "-")
        if parts.count == 2, parts[0].count == 8, parts[1].count == 16,
           parts.allSatisfy({ part in part.unicodeScalars.allSatisfy { hex.contains($0) } }) { return true }
        return false
    }

    /// Finds a complete UDID embedded in free text (a filename). Handles both
    /// dashed (00008110-000E34240250201E) and bare 40-hex forms.
    static func scanForUDID(in text: String) -> String? {
        let dashed = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}")
        let bare = try? NSRegularExpression(pattern: "[0-9A-Fa-f]{40}")
        let range = NSRange(text.startIndex..., in: text)
        if let match = dashed?.firstMatch(in: text, range: range),
           let start = Range(match.range, in: text) {
            return String(text[start])
        }
        if let match = bare?.firstMatch(in: text, range: range),
           let start = Range(match.range, in: text) {
            return String(text[start])
        }
        return nil
    }
}

struct DevicePairingStatus: Equatable, Sendable {
    let hasRecord: Bool
    let recordValid: Bool
    /// nil when the app cannot know this device's UDID (no AltStore injection
    /// and no UDID entered yet), so the match cannot be checked honestly.
    let deviceIdentifierMatches: Bool?
    /// nil until the direct transport exists (Phase 3) and a real handshake ran.
    let connectionReachable: Bool?
    let lastValidated: Date?

    static let empty = DevicePairingStatus(hasRecord: false, recordValid: false,
                                           deviceIdentifierMatches: nil, connectionReachable: nil,
                                           lastValidated: nil)

    var isUsable: Bool {
        hasRecord && recordValid && deviceIdentifierMatches != false
    }

    var summary: String {
        guard hasRecord else { return "No pairing record" }
        guard recordValid else { return "Pairing record invalid" }
        switch deviceIdentifierMatches {
        case .some(false): return "Pairing record belongs to another device"
        case .some(true): return "Paired with this iPhone"
        case nil: return "Paired · device match not verifiable yet"
        }
    }
}

enum DevicePairingValidator {
    static func status(records: [DevicePairingRecord],
                       expectedUDID: String?,
                       connectionReachable: Bool? = nil,
                       lastValidated: Date? = nil) -> DevicePairingStatus {
        guard let record = records.first else { return .empty }
        let expected = expectedUDID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: Bool?
        if let expected, !expected.isEmpty {
            matches = record.udid.caseInsensitiveCompare(expected) == .orderedSame
        } else {
            matches = nil
        }
        return DevicePairingStatus(hasRecord: true,
                                   recordValid: true,
                                   deviceIdentifierMatches: matches,
                                   connectionReachable: connectionReachable,
                                   lastValidated: lastValidated)
    }
}

// MARK: - Pairing storage

protocol DevicePairingStoring: Sendable {
    func records() -> [DevicePairingRecord]
    func save(_ record: DevicePairingRecord) throws
    func remove(udid: String)
}

/// Keychain-backed store: `ThisDeviceOnly`, never synced, never in backups.
final class KeychainDevicePairingStore: DevicePairingStoring, @unchecked Sendable {
    private let service = "com.forgesign.mobile.device-pairing"
    private let lock = NSLock()

    func records() -> [DevicePairingRecord] {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data,
                  case .success(let record) = DevicePairingRecord.parse(data: data) else { return nil }
            return record
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    func save(_ record: DevicePairingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        // NOTE: must not call remove(udid:) here — remove() locks the same
        // non-recursive NSLock and would deadlock the importing thread.
        // Duplicates are handled by SecItemAdd's errSecDuplicateItem below.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: record.udid,
            kSecAttrLabel as String: "ForgeSign device pairing record",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: record.payload
        ]
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // An update path (re-import, in-place pair-setup refresh): replace
            // the stored payload without a nested lock.
            let update: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: record.udid
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: record.payload,
                kSecAttrLabel as String: "ForgeSign device pairing record"
            ]
            status = SecItemUpdate(update as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw DevicePairingError.storageFailed("Keychain error \(status).")
        }
    }

    func remove(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Test double — keeps pairing records in memory only.
final class InMemoryDevicePairingStore: DevicePairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: DevicePairingRecord] = [:]

    func records() -> [DevicePairingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.addedAt > $1.addedAt }
    }

    func save(_ record: DevicePairingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[record.udid] = record
    }

    func remove(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[udid] = nil
    }
}

// MARK: - Tunnel endpoints
//
// Nothing here assumes a fixed address: these are probe candidates. The real
// tunnel address is whatever the running VPN exposes; the probe reports what is
// actually reachable, and a custom host overrides the list.

struct DeviceTunnelEndpoint: Equatable, Sendable {
    enum Source: String, Sendable {
        case localDevVPN = "LocalDevVPN"
        case loopback = "Loopback"
        case custom = "Custom"
        /// The device's own remote-pairing listener, discovered via Bonjour.
        case deviceListener = "Device listener"
    }

    let host: String
    let port: UInt16?
    let source: Source

    var display: String { port.map { "\(host):\($0)" } ?? host }
}

enum DeviceTunnelCandidates {
    /// Lockdown's well-known port. RSD ports are dynamic and are discovered in
    /// Phase 5, never assumed.
    static let lockdownPort: UInt16 = 62078

    static func endpoints(customHost: String? = nil) -> [DeviceTunnelEndpoint] {
        var endpoints: [DeviceTunnelEndpoint] = []
        if let customHost, !customHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endpoints.append(DeviceTunnelEndpoint(host: customHost, port: lockdownPort, source: .custom))
        }
        endpoints.append(DeviceTunnelEndpoint(host: "10.7.0.1", port: lockdownPort, source: .localDevVPN))
        endpoints.append(DeviceTunnelEndpoint(host: "10.6.0.1", port: lockdownPort, source: .localDevVPN))
        endpoints.append(DeviceTunnelEndpoint(host: "127.0.0.1", port: lockdownPort, source: .loopback))
        return endpoints
    }
}

protocol DevicePortProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool
}

enum DeviceTunnelProbe {
    /// Probes every candidate concurrently and returns the first reachable one;
    /// losers are cancelled when the group exits.
    static func firstReachable(endpoints: [DeviceTunnelEndpoint],
                               prober: DevicePortProbing,
                               timeout: TimeInterval = 3) async -> DeviceTunnelEndpoint? {
        guard !endpoints.isEmpty else { return nil }
        return await withTaskGroup(of: DeviceTunnelEndpoint?.self) { group in
            for endpoint in endpoints {
                guard let port = endpoint.port else { continue }
                group.addTask {
                    let reachable = await prober.probe(host: endpoint.host, port: port, timeout: timeout)
                    return reachable ? endpoint : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}

// MARK: - Health

struct DeviceInstallHealthRow: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case ok
        case warning
        case failed
        case unknown
        case unavailable

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle.fill"
            case .unavailable: return "minus.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let detail: String
    let isRetryable: Bool
}

struct DeviceInstallHealth: Equatable, Sendable {
    let rows: [DeviceInstallHealthRow]
    let checkedAt: Date

    var worst: DeviceInstallHealthRow.Status {
        if rows.contains(where: { $0.status == .failed }) { return .failed }
        if rows.contains(where: { $0.status == .warning }) { return .warning }
        if rows.contains(where: { $0.status == .unknown }) { return .unknown }
        if rows.contains(where: { $0.status == .unavailable }) { return .unavailable }
        return .ok
    }

    var summary: String {
        switch worst {
        case .ok: return "All checks passed"
        case .warning: return "Needs attention"
        case .failed: return "Installation unavailable"
        case .unknown: return "Not fully checked yet"
        case .unavailable: return "Not implemented yet"
        }
    }
}

enum DeviceInstallHealthService {
    static func makeHealth(pairing: DevicePairingStatus,
                           tunnel: DeviceTunnelEndpoint?,
                           tunnelProbed: Bool,
                           availableMethods: [InstallationMethod],
                           osVersion: String,
                           serviceProbe: DeviceServiceProbeResult? = nil,
                           now: Date = Date()) -> DeviceInstallHealth {
        var rows: [DeviceInstallHealthRow] = []

        rows.append(DeviceInstallHealthRow(id: "os", title: "iOS", status: .ok,
                                           detail: osVersion, isRetryable: false))

        let pairingStatus: DeviceInstallHealthRow.Status
        switch (pairing.hasRecord, pairing.recordValid, pairing.deviceIdentifierMatches) {
        case (false, _, _): pairingStatus = .warning
        case (true, false, _): pairingStatus = .failed
        case (true, true, .some(false)): pairingStatus = .failed
        default: pairingStatus = .ok
        }
        rows.append(DeviceInstallHealthRow(id: "pairing", title: "Pairing record",
                                           status: pairingStatus,
                                           detail: pairing.summary, isRetryable: true))

        let tunnelStatus: DeviceInstallHealthRow.Status
        let tunnelDetail: String
        if let tunnel {
            tunnelStatus = .ok
            tunnelDetail = "Reachable at \(tunnel.display) (\(tunnel.source.rawValue))"
        } else if tunnelProbed {
            tunnelStatus = .failed
            tunnelDetail = "No tunnel endpoint answered. Start LocalDevVPN, then retry."
        } else {
            tunnelStatus = .unknown
            tunnelDetail = "Not checked yet."
        }
        rows.append(DeviceInstallHealthRow(id: "tunnel", title: "Local tunnel",
                                           status: tunnelStatus, detail: tunnelDetail, isRetryable: true))

        let directAvailable = availableMethods.contains(.directDevice)
        // Device service / Installer service reflect the *probe*, not flags.
        func serviceRow(id: String, title: String) -> DeviceInstallHealthRow {
            if let probe = serviceProbe {
                switch probe.state {
                case .ok:
                    return DeviceInstallHealthRow(id: id, title: title, status: .ok,
                                                  detail: probe.detail, isRetryable: true)
                case .failed:
                    return DeviceInstallHealthRow(id: id, title: title, status: .failed,
                                                  detail: probe.detail, isRetryable: true)
                case .unavailable:
                    return DeviceInstallHealthRow(id: id, title: title, status: .unavailable,
                                                  detail: probe.detail, isRetryable: false)
                }
            }
            return DeviceInstallHealthRow(id: id, title: title,
                                          status: directAvailable ? .unknown : .unavailable,
                                          detail: directAvailable
                                              ? "Not exercised yet — run a full check."
                                              : "Ships with the direct-device transport.",
                                          isRetryable: directAvailable)
        }
        rows.append(serviceRow(id: "device-service", title: "Device service"))
        rows.append(serviceRow(id: "installer-service", title: "Installer service"))

        let remoteAvailable = availableMethods.contains(.remoteAltServer)
        rows.append(DeviceInstallHealthRow(id: "remote", title: "Remote AltServer",
                                           status: .unavailable,
                                           detail: "Not implemented. AltStore's remote mode is device pairing + a local tunnel, not a server API — use Device Installation above.",
                                           isRetryable: false))

        let otaAvailable = availableMethods.contains(.ota)
        rows.append(DeviceInstallHealthRow(id: "ota", title: "OTA fallback",
                                           status: otaAvailable ? .ok : .unavailable,
                                           detail: otaAvailable ? "Loopback server and manifest handoff are available."
                                                                : "Not registered in this build.",
                                           isRetryable: false))

        return DeviceInstallHealth(rows: rows, checkedAt: now)
    }
}

// MARK: - Sanitized diagnostics

enum SanitizedDiagnostics {
    /// Keeps a UDID recognisable to its owner without publishing it in full.
    static func mask(udid: String) -> String {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "••••" }
        return "\(trimmed.prefix(4))…\(trimmed.suffix(4))"
    }

    /// Redacted report. Never contains pairing payloads, private keys,
    /// certificates, passwords, or anisette identifiers.
    static func report(health: DeviceInstallHealth,
                       pairing: DevicePairingStatus,
                       records: [DevicePairingRecord],
                       availableMethods: [InstallationMethod],
                       appVersion: String,
                       osVersion: String,
                       anisetteSource: String) -> String {
        var lines: [String] = []
        lines.append("ForgeSign \(appVersion) · iOS \(osVersion)")
        lines.append("Installation methods: \(availableMethods.map(\.displayName).joined(separator: ", "))")
        lines.append("Anisette source: \(anisetteSource)")
        lines.append("")
        lines.append("DEVICE INSTALL HEALTH (\(health.summary))")
        for row in health.rows {
            lines.append("- \(row.title): \(row.status.rawValue) — \(row.detail)")
        }
        lines.append("")
        lines.append("PAIRING")
        lines.append("- records: \(records.count)")
        for record in records {
            lines.append("- \(record.displayName) · host ID \(record.hostID ?? "unknown") · "
                         + "certificate \(record.deviceCertificateFingerprint ?? "unknown") · "
                         + "added \(ISO8601DateFormatter().string(from: record.addedAt))")
        }
        if pairing.hasRecord, !pairing.recordValid {
            lines.append("- status: invalid")
        }
        lines.append("")
        lines.append("Pairing payloads, private keys, certificates, passwords and anisette identifiers are never included.")
        return lines.joined(separator: "\n")
    }
}