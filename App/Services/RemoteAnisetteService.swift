import Foundation
import CryptoKit
import Security

// MARK: - Remote anisette servers
//
// ForgeSign can obtain Apple sign-in (anisette) data without a local Mac:
// a community anisette server performs the ADI provisioning handshake and
// returns the machine ID / one-time password Apple expects. The protocol is
// the same one AltStore Classic ("no computer") and SideStore use:
//
//   1. GET  {server}/v3/client_info          → the client identity to report
//   2. POST {server}/v3/provisioning_session → WebSocket provisioning relay
//        (the Apple GSA start/finish requests below are made by this device)
//   3. POST {server}/v3/get_headers          → machineID + one-time password
//
// Older servers that only expose the legacy root `GET /` header endpoint are
// still supported as a fallback.

/// A community anisette server entry.
struct RemoteAnisetteServer: Identifiable, Hashable, Sendable {
    let name: String
    let address: String

    var id: String { address }

    var url: URL? {
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var host: String { url?.host ?? address }

    init?(name: String, address: String) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedAddress),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name
        self.address = trimmedAddress
    }
}

enum RemoteAnisetteCatalog {
    /// Published community anisette servers (the SideStore server list).
    static let bundled: [RemoteAnisetteServer] = [
        ("SideStore", "https://ani.sidestore.io"),
        ("SideStore (.app)", "https://ani.sidestore.app"),
        ("SideStore (.zip)", "https://ani.sidestore.zip"),
        ("nythepegasus", "https://ani.npeg.us"),
        ("WE. Studio", "https://anisette.wedotstud.io"),
        ("SteX", "https://ani.xu30.top"),
        ("owoellen", "https://ani.owoellen.rocks"),
        ("iDH Server", "https://ani.idevicehacked.com"),
        ("neoarz", "https://ani.neoarz.com"),
        ("Jayden's Server", "https://ani.jaydenha.uk"),
        ("crystall1nedev", "https://anisette.crystall1ne.dev"),
        ("ethxn (omnisette)", "https://omni.ethxn.xyz")
    ].compactMap { RemoteAnisetteServer(name: $0.0, address: $0.1) }

    /// Upstream list ForgeSign can refresh itself from.
    static let publishedListURL = URL(string: "https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json")!

    private static let storedServersKey = "forgesign.anisette.serverList"

    /// Bundled servers plus any list the user refreshed or added, de-duplicated.
    static func available() -> [RemoteAnisetteServer] {
        var seen = Set<String>()
        var result: [RemoteAnisetteServer] = []
        for server in bundled + stored() where seen.insert(server.address).inserted {
            result.append(server)
        }
        return result
    }

    static func stored() -> [RemoteAnisetteServer] {
        guard let raw = UserDefaults.standard.array(forKey: storedServersKey) as? [[String: String]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let name = entry["name"], let address = entry["address"] else { return nil }
            return RemoteAnisetteServer(name: name, address: address)
        }
    }

    static func store(_ servers: [RemoteAnisetteServer]) {
        let raw = servers.map { ["name": $0.name, "address": $0.address] }
        UserDefaults.standard.set(raw, forKey: storedServersKey)
    }

    /// Downloads the published server list. Returns nil when the list is unreachable.
    static func fetchPublished(using session: URLSession = .shared) async -> [RemoteAnisetteServer]? {
        var request = URLRequest(url: publishedListURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return servers(fromPublishedList: data)
    }

    /// Parses the published `{"servers":[{"name":…,"address":…}]}` document, and
    /// also accepts a bare array of server entries.
    static func servers(fromPublishedList data: Data) -> [RemoteAnisetteServer]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let root = object as? [String: Any], let list = root["servers"] as? [[String: Any]] {
            entries = list
        } else if let root = object as? [[String: Any]] {
            entries = root
        } else {
            return nil
        }
        let servers = entries.compactMap { entry -> RemoteAnisetteServer? in
            guard let name = entry["name"] as? String, let address = entry["address"] as? String else { return nil }
            return RemoteAnisetteServer(name: name, address: address)
        }
        return servers.isEmpty ? nil : servers
    }

    static func server(forAddress address: String) -> RemoteAnisetteServer? {
        available().first { $0.address == address }
    }
}

// MARK: - Errors

enum RemoteAnisetteError: LocalizedError, Sendable {
    case invalidServer(String)
    case unreachable(String, String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case provisioningFailed(String)
    case timedOut(String)
    case noDataSource

    var errorDescription: String? {
        switch self {
        case .invalidServer(let detail):
            return detail
        case .unreachable(let host, let detail):
            return detail.isEmpty ? "Could not reach \(host)." : "Could not reach \(host): \(detail)"
        case .httpStatus(let status, let host):
            return "\(host) returned HTTP \(status)."
        case .invalidResponse(let detail):
            return detail.isEmpty
                ? "The anisette server returned an unexpected response."
                : "The anisette server returned an unexpected response: \(detail)"
        case .provisioningFailed(let detail):
            return "Anisette provisioning failed: \(detail)"
        case .timedOut(let stage):
            return "The anisette request timed out during \(stage)."
        case .noDataSource:
            return "No anisette source is enabled. Choose a remote server, AltServer, or This iPhone."
        }
    }
}

// MARK: - Device identity

/// The persistent pseudo-device identity an anisette server provisions against.
/// 16 random bytes → identifier (base64), local user ID (SHA-256) and device UUID.
struct AnisetteDeviceIdentity: Sendable, Equatable {
    static let byteCount = 16

    let bytes: Data

    init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    static func generate() -> AnisetteDeviceIdentity {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // The byte count is fixed, so this cannot fail.
        return AnisetteDeviceIdentity(bytes: data)!
    }

    var identifier: String { bytes.base64EncodedString() }

    var localUserID: String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    var deviceIdentifier: String {
        var uuid = UUID()
        withUnsafeMutableBytes(of: &uuid) { destination in
            _ = bytes.copyBytes(to: destination)
        }
        return uuid.uuidString
    }
}

enum AnisetteIdentityStore {
    private static let service = "com.forgesign.mobile.remote-anisette"
    private static let identityAccount = "device-identity"
    private static let provisioningAccount = "adi-pb"

    static func loadOrCreateIdentity() -> AnisetteDeviceIdentity {
        if let data = read(account: identityAccount),
           let identity = AnisetteDeviceIdentity(bytes: data) {
            return identity
        }
        let identity = AnisetteDeviceIdentity.generate()
        write(identity.bytes, account: identityAccount)
        return identity
    }

    static func cachedProvisioningBlob() -> Data? {
        read(account: provisioningAccount)
    }

    static func storeProvisioningBlob(_ data: Data) {
        write(data, account: provisioningAccount)
    }

    static func clearProvisioningBlob() {
        delete(account: provisioningAccount)
    }

    /// Wipes the identity and its provisioning blob. The next fetch starts fresh,
    /// which is what a server-side identity reset requires.
    static func reset() {
        delete(account: identityAccount)
        delete(account: provisioningAccount)
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client

struct RemoteAnisetteResult: Sendable {
    let json: [String: String]
    let serverName: String
    let usedProvisioning: Bool
}

/// Talks to a remote anisette server (v3 protocol with legacy fallback).
enum RemoteAnisetteClient {
    static let requestTimeout: TimeInterval = 12
    private static let provisioningStepTimeout: TimeInterval = 30
    private static let appleLookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func fetchAnisette(from server: RemoteAnisetteServer) async throws -> RemoteAnisetteResult {
        guard let base = server.url else {
            throw RemoteAnisetteError.invalidServer("\(server.name) does not have a usable address.")
        }

        var version3Error: Error?
        do {
            let json = try await fetchAnisetteVersion3(from: base, serverName: server.name)
            return RemoteAnisetteResult(json: json, serverName: server.name, usedProvisioning: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            version3Error = error
        }

        do {
            let json = try await fetchLegacyHeaders(from: base, serverName: server.name)
            return RemoteAnisetteResult(json: json, serverName: server.name, usedProvisioning: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteAnisetteError.unreachable(
                server.host,
                "\(error.localizedDescription) (\(version3Error?.localizedDescription ?? "v3 unavailable"))"
            )
        }
    }

    // MARK: v3

    private static func fetchAnisetteVersion3(from base: URL, serverName: String) async throws -> [String: String] {
        let client = try await fetchClientInformation(from: base, serverName: serverName)
        let identity = AnisetteIdentityStore.loadOrCreateIdentity()

        var cachedBlob = AnisetteIdentityStore.cachedProvisioningBlob()
        if cachedBlob == nil {
            let blob = try await provision(against: base, clientInfo: client.clientInfo,
                                           userAgent: client.userAgent, identity: identity)
            AnisetteIdentityStore.storeProvisioningBlob(blob)
            cachedBlob = blob
        }
        guard let blob = cachedBlob else {
            throw RemoteAnisetteError.provisioningFailed("the server did not return provisioning data.")
        }

        do {
            return try await headers(from: base, identity: identity, provisioningBlob: blob, serverName: serverName)
        } catch let error as RemoteAnisetteError {
            // A stale blob after a server reset is recoverable: re-provision once.
            guard case .invalidResponse = error else { throw error }
            AnisetteIdentityStore.clearProvisioningBlob()
            let fresh = try await provision(against: base, clientInfo: client.clientInfo,
                                            userAgent: client.userAgent, identity: identity)
            AnisetteIdentityStore.storeProvisioningBlob(fresh)
            return try await headers(from: base, identity: identity, provisioningBlob: fresh, serverName: serverName)
        }
    }

    struct ClientInformation: Sendable {
        let clientInfo: String
        let userAgent: String
    }

    static func fetchClientInformation(from base: URL, serverName: String) async throws -> ClientInformation {
        let url = base.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request, serverName: serverName)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteAnisetteError.invalidResponse("client_info is not JSON.")
        }
        let clientInfo = string(in: object, keys: ["client_info", "clientInfo"])
        let userAgent = string(in: object, keys: ["user_agent", "userAgent"])
        guard let clientInfo, let userAgent else {
            throw RemoteAnisetteError.invalidResponse("client_info is missing fields.")
        }
        return ClientInformation(clientInfo: clientInfo, userAgent: userAgent)
    }

    static func headers(from base: URL,
                        identity: AnisetteDeviceIdentity,
                        provisioningBlob: Data,
                        serverName: String) async throws -> [String: String] {
        var request = URLRequest(url: base.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identity.identifier,
            "adi_pb": provisioningBlob.base64EncodedString()
        ])

        let (data, _) = try await send(request, serverName: serverName)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteAnisetteError.invalidResponse("get_headers is not JSON.")
        }
        if let result = object["result"] as? String, result == "GetHeadersError" {
            let message = (object["message"] as? String) ?? "the server rejected the provisioning data."
            throw RemoteAnisetteError.invalidResponse(message)
        }
        guard let machineID = string(in: object, keys: ["X-Apple-I-MD-M", "machineID"]),
              let oneTimePassword = string(in: object, keys: ["X-Apple-I-MD", "oneTimePassword"]),
              let routingInfo = string(in: object, keys: ["X-Apple-I-MD-RINFO", "routingInfo"]) else {
            throw RemoteAnisetteError.invalidResponse("get_headers is missing the Apple headers.")
        }
        let clientInfo = string(in: object, keys: ["X-MMe-Client-Info", "deviceDescription"])
        guard let json = anisetteJSON(identity: identity,
                                      machineID: machineID,
                                      oneTimePassword: oneTimePassword,
                                      routingInfo: routingInfo,
                                      clientInfo: clientInfo) else {
            throw RemoteAnisetteError.invalidResponse("the returned headers could not be assembled.")
        }
        return json
    }

    /// Assembles the AltSign-shaped anisette dictionary ForgeSign signs in with.
    /// Returns nil when the required machine ID / one-time password are missing.
    static func anisetteJSON(identity: AnisetteDeviceIdentity,
                             machineID: String,
                             oneTimePassword: String,
                             routingInfo: String,
                             clientInfo: String?) -> [String: String]? {
        let raw: [String: String] = [
            "X-Apple-I-MD-M": machineID,
            "X-Apple-I-MD": oneTimePassword,
            "X-Apple-I-MD-RINFO": routingInfo,
            "X-Apple-I-MD-LU": identity.localUserID,
            "X-Mme-Device-Id": identity.deviceIdentifier,
            "X-Apple-I-SRL-NO": "0",
            "X-MMe-Client-Info": clientInfo ?? AnisettePayload.compatibilityClientDescription,
            "X-Apple-I-Client-Time": ISO8601DateFormatter().string(from: Date()),
            "X-Apple-Locale": Locale.current.identifier,
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "UTC"
        ]
        // The server supplies the client identity its provisioning data belongs
        // to, so the remote path keeps that identity instead of rewriting it.
        return AnisettePayload.json(from: raw)
    }

    // MARK: Legacy endpoint

    static func fetchLegacyHeaders(from base: URL, serverName: String) async throws -> [String: String] {
        var request = URLRequest(url: base)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await send(request, serverName: serverName)

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let json = AnisettePayload.json(from: AnisettePayload.stringify(object)) {
                return json
            }
        }
        throw RemoteAnisetteError.invalidResponse("the server did not return anisette headers.")
    }

    // MARK: Provisioning

    private struct AppleProvisioningLinks: Sendable {
        let start: URL
        let finish: URL
    }

    static func provision(against base: URL,
                          clientInfo: String,
                          userAgent: String,
                          identity: AnisetteDeviceIdentity) async throws -> Data {
        let links = try await appleProvisioningLinks(clientInfo: clientInfo, userAgent: userAgent, identity: identity)
        let socket = session.webSocketTask(with: try provisioningSocketURL(from: base))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        while true {
            let message = try await receiveText(from: socket, stage: "provisioning")
            guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                  let result = json["result"] as? String else {
                throw RemoteAnisetteError.invalidResponse("the provisioning session sent an unexpected message.")
            }

            switch result {
            case "GiveIdentifier":
                try await sendJSON(["identifier": identity.identifier], on: socket)

            case "GiveStartProvisioningData":
                let spim = try await appleStartProvisioning(url: links.start, clientInfo: clientInfo,
                                                            userAgent: userAgent, identity: identity)
                try await sendJSON(["spim": spim], on: socket)

            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String else {
                    throw RemoteAnisetteError.provisioningFailed("the server did not send its provisioning response.")
                }
                let finish = try await appleFinishProvisioning(url: links.finish, cpim: cpim, clientInfo: clientInfo,
                                                               userAgent: userAgent, identity: identity)
                try await sendJSON(["ptm": finish.ptm, "tk": finish.tk], on: socket)

            case "ProvisioningSuccess":
                guard let encoded = json["adi_pb"] as? String,
                      let blob = Data(base64Encoded: encoded), !blob.isEmpty else {
                    throw RemoteAnisetteError.provisioningFailed("the server did not return provisioning data.")
                }
                return blob

            default:
                let message = (json["message"] as? String) ?? "unexpected step “\(result)”."
                throw RemoteAnisetteError.provisioningFailed(message)
            }
        }
    }

    static func appleProvisioningLinks(clientInfo: String,
                                       userAgent: String,
                                       identity: AnisetteDeviceIdentity) async throws -> (start: URL, finish: URL) {
        var request = appleRequest(url: appleLookupURL, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
        request.httpMethod = "GET"
        let data = try await appleData(for: request, stage: "Apple sign-in lookup")
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urls = plist["urls"] as? [String: Any],
              let startString = urls["midStartProvisioning"] as? String,
              let finishString = urls["midFinishProvisioning"] as? String,
              let start = URL(string: startString),
              let finish = URL(string: finishString) else {
            throw RemoteAnisetteError.provisioningFailed("Apple did not return provisioning endpoints.")
        }
        return (start, finish)
    }

    static func appleStartProvisioning(url: URL,
                                       clientInfo: String,
                                       userAgent: String,
                                       identity: AnisetteDeviceIdentity) async throws -> String {
        var request = appleRequest(url: url, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
        request.httpMethod = "POST"
        request.httpBody = try plistBody(header: [:], request: [:])
        let data = try await appleData(for: request, stage: "Apple provisioning start")
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let spim = response["spim"] as? String, !spim.isEmpty else {
            throw RemoteAnisetteError.provisioningFailed("Apple did not return provisioning data.")
        }
        return spim
    }

    static func appleFinishProvisioning(url: URL,
                                        cpim: String,
                                        clientInfo: String,
                                        userAgent: String,
                                        identity: AnisetteDeviceIdentity) async throws -> (ptm: String, tk: String) {
        var request = appleRequest(url: url, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
        request.httpMethod = "POST"
        request.httpBody = try plistBody(header: [:], request: ["cpim": cpim])
        let data = try await appleData(for: request, stage: "Apple provisioning finish")
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let response = plist["Response"] as? [String: Any],
              let ptm = response["ptm"] as? String,
              let tk = response["tk"] as? String else {
            throw RemoteAnisetteError.provisioningFailed("Apple did not finish provisioning.")
        }
        return (ptm, tk)
    }

    // MARK: Request plumbing

    static func appleRequest(url: URL,
                             clientInfo: String,
                             userAgent: String,
                             identity: AnisetteDeviceIdentity) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(identity.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(identity.deviceIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation() ?? "UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
        request.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        return request
    }

    static func plistBody(header: [String: String], request: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Header": header, "Request": request],
                                           format: .xml, options: 0)
    }

    private static func appleData(for request: URLRequest, stage: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw RemoteAnisetteError.provisioningFailed("\(stage) returned HTTP \(http.statusCode).")
            }
            return data
        } catch let error as RemoteAnisetteError {
            throw error
        } catch {
            throw RemoteAnisetteError.provisioningFailed("\(stage) failed: \(error.localizedDescription)")
        }
    }

    static func provisioningSocketURL(from base: URL) throws -> URL {
        let sessionURL = base.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
        guard var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: true) else {
            throw RemoteAnisetteError.invalidServer("The anisette server address is not usable.")
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else {
            throw RemoteAnisetteError.invalidServer("The anisette server address is not usable.")
        }
        return url
    }

    private static func send(_ request: URLRequest, serverName: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteAnisetteError.invalidResponse("the server did not send an HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RemoteAnisetteError.httpStatus(http.statusCode, serverName)
            }
            return (data, http)
        } catch let error as RemoteAnisetteError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteAnisetteError.unreachable(serverName, error.localizedDescription)
        }
    }

    private static func sendJSON(_ payload: [String: String], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.send(.string(String(decoding: data, as: UTF8.self))) { error in
                if let error {
                    continuation.resume(throwing: RemoteAnisetteError.provisioningFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func receiveText(from socket: URLSessionWebSocketTask, stage: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = RemoteContinuationGate(continuation)
            socket.receive { result in
                switch result {
                case .success(.string(let text)):
                    gate.resume(returning: text)
                case .success(.data(let data)):
                    gate.resume(returning: String(decoding: data, as: UTF8.self))
                case .success:
                    gate.resume(throwing: RemoteAnisetteError.invalidResponse("the provisioning session sent an unsupported message."))
                case .failure(let error):
                    gate.resume(throwing: RemoteAnisetteError.provisioningFailed(error.localizedDescription))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + provisioningStepTimeout) {
                if gate.resume(throwing: RemoteAnisetteError.timedOut(stage)) {
                    socket.cancel(with: .abnormalClosure, reason: nil)
                }
            }
        }
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
            if let value = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                if let text = value as? String, !text.isEmpty { return text }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }
}

/// Resumes a continuation exactly once — receive callbacks and the timeout can
/// race, and a double resume would trap.
private final class RemoteContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
