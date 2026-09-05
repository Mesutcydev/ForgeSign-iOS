import Foundation
import Network

struct AltServerDescriptor: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let name: String
    fileprivate let endpoint: NWEndpoint
}

enum AltServerClientError: LocalizedError, Sendable {
    case noServer
    case connectionFailed(String)
    case invalidFrame
    case invalidResponse
    case serverRejected(Int?, String?)
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .noServer:
            return "No AltServer was selected. Keep AltServer running and connect both devices to the same network, or enter an anisette server URL."
        case .connectionFailed(let detail):
            return "Could not connect to AltServer: \(detail)"
        case .invalidFrame:
            return "AltServer returned an incomplete response."
        case .invalidResponse:
            return "AltServer returned an unsupported anisette response."
        case .serverRejected(_, let message) where message?.localizedCaseInsensitiveContains("machineID") == true:
            return "AltServer on macOS 27 could not create anisette data (missing machineID). ForgeSign will use this iPhone or an anisette server instead."
        case .serverRejected(let code, let message):
            if let message, !message.isEmpty { return message }
            if let code { return "AltServer rejected the anisette request (error \(code))." }
            return "AltServer rejected the anisette request."
        case .allSourcesFailed(let details):
            let suffix = details.isEmpty ? "" : " \(details.joined(separator: " "))"
            return "Could not get Apple login data. On macOS 27 AltServer cannot read machineID. Use this iPhone, or run an anisette server on your Mac (http://YOUR-MAC-IP:6969) and enter that URL.\(suffix)"
        }
    }
}

enum AltServerWireProtocol {
    private struct AnisetteRequest: Encodable {
        let version = 1
        let identifier = "AnisetteDataRequest"
    }

    static func anisetteRequestFrame() throws -> Data {
        let payload = try JSONEncoder().encode(AnisetteRequest())
        guard payload.count <= Int(Int32.max) else { throw AltServerClientError.invalidFrame }
        var size = Int32(payload.count)
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)
        return frame
    }

    static func responseSize(from header: Data) throws -> Int {
        guard header.count == MemoryLayout<Int32>.size else {
            throw AltServerClientError.invalidFrame
        }
        let size = header.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: Int32.self)
        }
        guard size > 0, size <= 2_000_000 else { throw AltServerClientError.invalidFrame }
        return Int(size)
    }

    static func anisetteData(from payload: Data) throws -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let identifier = root["identifier"] as? String else {
            throw AltServerClientError.invalidResponse
        }
        if identifier == "ErrorResponse" {
            throw AltServerClientError.serverRejected(errorCode(in: root), errorMessage(in: root))
        }
        guard identifier == "AnisetteDataResponse" else {
            throw AltServerClientError.invalidResponse
        }
        let version = (root["version"] as? Int)
            ?? (root["version"] as? NSNumber)?.intValue
            ?? 0
        guard version >= 1,
              let object = root["anisetteData"] as? [String: Any] else {
            throw AltServerClientError.invalidResponse
        }
        let data = AnisettePayload.stringify(object)
        guard !data.isEmpty else { throw AltServerClientError.invalidResponse }
        return data
    }

    private static func errorCode(in root: [String: Any]) -> Int? {
        if let code = root["errorCode"] as? Int { return code }
        if let code = (root["errorCode"] as? NSNumber)?.intValue { return code }
        if let error = root["error"] as? [String: Any] {
            if let code = error["errorCode"] as? Int { return code }
            if let code = (error["errorCode"] as? NSNumber)?.intValue { return code }
            if let code = error["code"] as? Int { return code }
        }
        return nil
    }

    private static func errorMessage(in root: [String: Any]) -> String? {
        if let message = root["errorDescription"] as? String, !message.isEmpty { return message }
        if let message = root["errorMessage"] as? String, !message.isEmpty { return message }
        if let message = root["error"] as? String, !message.isEmpty { return message }
        if let error = root["error"] as? [String: Any] {
            for key in ["localizedDescription", "errorDescription", "errorMessage", "reason"] {
                if let message = error[key] as? String, !message.isEmpty { return message }
            }
        }
        return nil
    }
}

@MainActor
final class AltServerClient: ObservableObject {
    @Published private(set) var servers: [AltServerDescriptor] = []
    @Published private(set) var isSearching = false
    @Published private(set) var discoveryError: String?
    @Published private(set) var lastSource: AnisetteSource?
    @Published var selectedServerID: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.forgesign.altserver.discovery", qos: .userInitiated)

    func startSearching() {
        guard browser == nil else { return }
        discoveryError = nil
        isSearching = true

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_altserver._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed(let error):
                    self.discoveryError = error.localizedDescription
                    self.isSearching = false
                    self.browser?.cancel()
                    self.browser = nil
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discovered = results.compactMap { result -> AltServerDescriptor? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return AltServerDescriptor(id: String(describing: result.endpoint),
                                           name: name,
                                           endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self else { return }
                self.servers = discovered
                if self.selectedServerID == nil || !discovered.contains(where: { $0.id == self.selectedServerID }) {
                    self.selectedServerID = discovered.first?.id
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    func fetchAnisetteData(httpURL: URL? = nil) async throws -> [String: String] {
        var failures: [String] = []

        if let onDevice = OnDeviceAnisette.json() {
            lastSource = .thisDevice
            return onDevice
        }

        if let server = selectedServer {
            let connection = AltServerConnection(endpoint: server.endpoint)
            do {
                let raw = try await connection.fetchAnisetteData()
                if let json = AnisettePayload.json(from: raw) {
                    lastSource = .altServer
                    return json
                }
                failures.append("AltServer sent incomplete anisette data.")
            } catch {
                failures.append(error.localizedDescription)
            }

            if let host = connection.resolvedHost,
               let fallback = Self.httpURL(host: host, port: 6969) {
                do {
                    let json = try await AnisetteHTTPClient.fetch(from: fallback)
                    lastSource = .altServerHost
                    return json
                } catch {
                    failures.append("No anisette HTTP server on \(host):6969.")
                }
            }
        } else {
            failures.append(AltServerClientError.noServer.localizedDescription)
        }

        if let httpURL {
            do {
                let json = try await AnisetteHTTPClient.fetch(from: httpURL)
                lastSource = .httpServer
                return json
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        lastSource = nil
        throw AltServerClientError.allSourcesFailed(failures)
    }

    var hasAnisetteSource: Bool {
        selectedServer != nil || OnDeviceAnisette.isAvailable
    }

    private static func httpURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }

    var selectedServer: AltServerDescriptor? {
        servers.first { $0.id == selectedServerID }
    }
}

private final class AltServerConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.forgesign.altserver.connection", qos: .userInitiated)
    private(set) var resolvedHost: String?

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    func fetchAnisetteData() async throws -> [String: String] {
        let timeout = Task { [connection] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer {
            timeout.cancel()
            connection.cancel()
        }
        try await connect()
        try await send(AltServerWireProtocol.anisetteRequestFrame())
        let header = try await receiveExactly(MemoryLayout<Int32>.size)
        let payloadSize = try AltServerWireProtocol.responseSize(from: header)
        let payload = try await receiveExactly(payloadSize)
        return try AltServerWireProtocol.anisetteData(from: payload)
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _) = self.connection.currentPath?.remoteEndpoint {
                        self.resolvedHost = "\(host)"
                    }
                    gate.resume(returning: ())
                case .failed(let error):
                    gate.resume(throwing: AltServerClientError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    gate.resume(throwing: AltServerClientError.connectionFailed("The connection was cancelled."))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AltServerClientError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await receiveChunk(maximumLength: remaining)
            guard !chunk.isEmpty else { throw AltServerClientError.invalidFrame }
            result.append(chunk)
        }
        return result
    }

    private func receiveChunk(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: AltServerClientError.connectionFailed(error.localizedDescription))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AltServerClientError.invalidFrame)
                }
            }
        }
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
