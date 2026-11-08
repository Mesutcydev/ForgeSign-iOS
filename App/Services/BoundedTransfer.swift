import Foundation
import Darwin

struct TransferProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var description: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        guard let totalBytes else { return received }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }
}

/// A foreground HTTPS transfer whose on-disk file never exceeds its budget.
/// File I/O and delegate state stay on one serial queue. Only cancellation and
/// its task reference cross threads, protected by controlLock.
final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError, Equatable, Sendable {
        case invalidURL, invalidResponse, tooLarge, sizeMismatch, empty, storage

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Downloads must use a safe HTTPS URL."
            case .invalidResponse: "The server did not return a successful download."
            case .tooLarge: "The download exceeds the allowed size."
            case .sizeMismatch: "The download size does not match the repository."
            case .empty: "The server returned an empty download."
            case .storage: "The download could not be saved. Check available storage and try again."
            }
        }
    }

    private let destination: URL
    private let maximumBytes: Int64
    private let expectedBytes: Int64?
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (TransferProgress) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ForgeSign.bounded-transfer"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let controlLock = NSLock()
    private var cancellationRequested = false
    private var task: URLSessionDataTask?

    // Accessed only on queue.
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: URLSession?
    private var file: FileHandle?
    private var ownsDestination = false
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64?
    private var receivedResponse = false
    private var finished = false
    private var lastProgressTime: TimeInterval = 0

    init(destination: URL, maximumBytes: Int64, expectedBytes: Int64? = nil,
         configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.expectedBytes = expectedBytes
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        guard NetworkPolicy.validateHTTPS(url) else { throw Failure.invalidURL }
        guard maximumBytes > 0 else { throw Failure.tooLarge }
        if let expectedBytes, expectedBytes <= 0 || expectedBytes > maximumBytes { throw Failure.tooLarge }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { self.begin(url: url, continuation: continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let currentTask = controlLock.withLock {
            cancellationRequested = true
            return task
        }
        currentTask?.cancel()
        queue.addOperation {
            // Do not depend on a stalled server (or URLProtocol) delivering
            // another delegate callback before releasing the partial file.
            if self.continuation != nil { self.finish(throwing: CancellationError()) }
        }
    }

    private var isCancelled: Bool { controlLock.withLock { cancellationRequested } }

    private func begin(url: URL, continuation: CheckedContinuation<URL, any Error>) {
        precondition(self.continuation == nil && !finished, "Use one BoundedTransfer per download")
        self.continuation = continuation
        if isCancelled { finish(throwing: CancellationError()); return }
        // The caller supplies a new UUID path. Never replace an existing file.
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            finish(throwing: Failure.storage)
            return
        }
        ownsDestination = true
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        } catch {
            finish(throwing: Failure.storage)
            return
        }
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        let shouldStart = controlLock.withLock {
            self.task = task
            return !cancellationRequested
        }
        guard shouldStart else { finish(throwing: CancellationError()); return }
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(NetworkPolicy.validatedRedirect(request))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, !isCancelled else {
            completionHandler(.cancel)
            finish(throwing: CancellationError())
            return
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let url = response.url, NetworkPolicy.validateHTTPS(url) else {
            completionHandler(.cancel)
            finish(throwing: Failure.invalidResponse)
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(throwing: Failure.tooLarge)
            return
        }
        totalBytes = expectedBytes ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        receivedResponse = true
        progress(TransferProgress(receivedBytes: 0, totalBytes: totalBytes))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard !isCancelled else { finish(throwing: CancellationError()); return }
        guard receivedResponse, let file else { finish(throwing: Failure.invalidResponse); return }
        guard Int64(data.count) <= maximumBytes - receivedBytes else {
            finish(throwing: Failure.tooLarge)
            return
        }
        do {
            try file.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressTime >= 0.1 {
                lastProgressTime = now
                progress(TransferProgress(receivedBytes: receivedBytes, totalBytes: totalBytes))
            }
        } catch {
            finish(throwing: Failure.storage)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !finished else { return }
        if isCancelled || (error as? URLError)?.code == .cancelled {
            finish(throwing: CancellationError())
        } else if let error {
            finish(throwing: error)
        } else if !receivedResponse {
            finish(throwing: Failure.invalidResponse)
        } else if receivedBytes == 0 {
            finish(throwing: Failure.empty)
        } else if let expectedBytes, receivedBytes != expectedBytes {
            finish(throwing: Failure.sizeMismatch)
        } else {
            finish(throwing: nil)
        }
    }

    private func finish(throwing error: (any Error)?) {
        guard !finished else { return }
        finished = true
        var failure = error
        do { try file?.close() } catch { failure = failure ?? Failure.storage }
        file = nil
        let continuation = continuation
        self.continuation = nil
        controlLock.withLock { task = nil }
        if failure != nil {
            session?.invalidateAndCancel()
            if ownsDestination { try? FileManager.default.removeItem(at: destination) }
        } else {
            session?.finishTasksAndInvalidate()
            progress(TransferProgress(receivedBytes: receivedBytes, totalBytes: totalBytes))
        }
        session = nil
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: destination) }
    }
}
