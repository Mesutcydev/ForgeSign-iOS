import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Bounded repository transfers", .timeLimit(.minutes(1)))
struct BoundedTransferTests {
    private func fixture(_ handler: @escaping @Sendable (TransferProtocol) -> Void) throws -> (URL, URL) {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = URL(string: "https://downloads.example.invalid/\(id)")!
        TransferRoutes.shared.set(handler, for: url)
        return (url, directory.appendingPathComponent("download.partial"))
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferProtocol.self]
        return configuration
    }

    private func cleanup(_ remote: URL, _ destination: URL) {
        TransferRoutes.shared.remove(remote)
        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }

    @Test("Unknown-length streams stop at the byte budget and remove partials")
    func chunkedOversize() async throws {
        let (url, file) = try fixture { request in
            request.respond(chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 6)])
        }
        defer { cleanup(url, file) }
        let transfer = BoundedTransfer(destination: file, maximumBytes: 10, configuration: configuration())
        await #expect(throws: BoundedTransfer.Failure.tooLarge) { try await transfer.download(from: url) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("An advertised oversized response is refused before writing a body")
    func advertisedOversize() async throws {
        let (url, file) = try fixture { $0.respond(length: 100, chunks: [Data([1])]) }
        defer { cleanup(url, file) }
        let transfer = BoundedTransfer(destination: file, maximumBytes: 10, configuration: configuration())
        await #expect(throws: BoundedTransfer.Failure.tooLarge) { try await transfer.download(from: url) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A completed transfer preserves exactly the expected bytes")
    func success() async throws {
        let payload = Data("verified download".utf8)
        let (url, file) = try fixture { $0.respond(length: Int64(payload.count), chunks: [payload]) }
        defer { cleanup(url, file) }
        let transfer = BoundedTransfer(destination: file, maximumBytes: 1_024,
                                       expectedBytes: Int64(payload.count), configuration: configuration())
        let result = try await transfer.download(from: url)
        #expect(try Data(contentsOf: result) == payload)
    }

    @Test("Mismatched catalog sizes and HTTP failures never produce an IPA")
    func invalidResponse() async throws {
        let (url, file) = try fixture { $0.respond(length: 3, chunks: [Data([1, 2, 3])]) }
        defer { cleanup(url, file) }
        let transfer = BoundedTransfer(destination: file, maximumBytes: 100, expectedBytes: 4,
                                       configuration: configuration())
        await #expect(throws: BoundedTransfer.Failure.sizeMismatch) { try await transfer.download(from: url) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let (badURL, badFile) = try fixture { $0.respond(status: 403, chunks: [Data([1])]) }
        defer { cleanup(badURL, badFile) }
        let rejected = BoundedTransfer(destination: badFile, maximumBytes: 100, configuration: configuration())
        await #expect(throws: BoundedTransfer.Failure.invalidResponse) { try await rejected.download(from: badURL) }
        #expect(!FileManager.default.fileExists(atPath: badFile.path))
    }

    @Test("Cancellation closes a live stream and removes its partial file")
    func cancellation() async throws {
        let (updates, emitter) = AsyncStream<Void>.makeStream()
        defer { emitter.finish() }
        let (url, file) = try fixture {
            $0.respond(chunks: [Data([1, 2, 3])], finish: false)
            emitter.yield(())
        }
        defer { cleanup(url, file) }
        let transfer = BoundedTransfer(destination: file, maximumBytes: 100,
                                       configuration: configuration())
        let operation = Task { try await transfer.download(from: url) }
        for await _ in updates {
            transfer.cancel()
            break
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A transfer cannot truncate or delete an existing destination")
    func exclusiveDestination() async throws {
        let (url, file) = try fixture { $0.respond(chunks: [Data([1])]) }
        defer { cleanup(url, file) }
        let original = Data("keep this file".utf8)
        try original.write(to: file)
        let transfer = BoundedTransfer(destination: file, maximumBytes: 100, configuration: configuration())
        await #expect(throws: BoundedTransfer.Failure.storage) { try await transfer.download(from: url) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Redirects cannot downgrade to HTTP, local URLs, or credential URLs")
    func redirects() {
        for text in ["http://example.com/icon.png", "file:///tmp/icon.png", "https://localhost/icon.png", "https://user:pass@example.com/icon.png"] {
            #expect(NetworkPolicy.validatedRedirect(URLRequest(url: URL(string: text)!)) == nil)
        }
        #expect(NetworkPolicy.validatedRedirect(URLRequest(url: URL(string: "https://example.com/icon.png")!)) != nil)
    }

    @Test("Relaunch removes abandoned transfers while preserving complete IPAs")
    @MainActor
    func abandonedTransfers() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let downloads = base.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in [".download-fixture.partial", "complete.ipa", "other.partial"] {
            try Data([1]).write(to: downloads.appendingPathComponent(name))
        }
        _ = RepositoryStore(baseDirectory: base)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: downloads.path)) == ["complete.ipa", "other.partial"])
    }
}

private final class TransferRoutes: @unchecked Sendable {
    static let shared = TransferRoutes()
    private let lock = NSLock()
    private var handlers: [URL: @Sendable (TransferProtocol) -> Void] = [:]
    func set(_ handler: @escaping @Sendable (TransferProtocol) -> Void, for url: URL) {
        lock.withLock { handlers[url] = handler }
    }
    func handler(for url: URL) -> (@Sendable (TransferProtocol) -> Void)? { lock.withLock { handlers[url] } }
    func remove(_ url: URL) { _ = lock.withLock { handlers.removeValue(forKey: url) } }
}

private final class TransferProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "downloads.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let handler = TransferRoutes.shared.handler(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func respond(status: Int = 200, length: Int64? = nil, chunks: [Data], finish: Bool = true) {
        let headers = length.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}
