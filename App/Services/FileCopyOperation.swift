import Foundation
import Darwin

/// Copies large inputs on its own utility queue. Promotion is atomic, so a
/// cancelled or failed copy never removes the previous destination.
final class FileCopyOperation: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable, Sendable {
        case busy, invalidDestination, unreadable, tooLarge, changed, storage
        var errorDescription: String? {
            switch self {
            case .busy: "Wait for the current operation to finish before choosing another input."
            case .invalidDestination: "The input cannot be saved at this location."
            case .unreadable: "The selected file could not be read. Choose it again."
            case .tooLarge: "This original package is larger than the refresh storage budget."
            case .changed: "The selected file changed while it was being copied. Choose it again."
            case .storage: "The file could not be copied. Check available storage and try again."
            }
        }
    }

    private let queue = DispatchQueue(label: "ForgeSign.file-copy", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private let progress: @Sendable (TransferProgress) -> Void

    init(progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) {
        self.progress = progress
    }

    func cancel() { lock.withLock { cancelled = true } }
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func copy(from source: URL, to destination: URL, maximumBytes: Int64 = .max) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.perform(source, destination, maximumBytes)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func perform(_ source: URL, _ destination: URL, _ maximumBytes: Int64) throws -> URL {
        try checkCancellation()
        guard source.isFileURL, destination.isFileURL else { throw Failure.invalidDestination }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch { throw Failure.unreadable }
        defer { try? input.close() }
        var metadata = stat()
        guard fstat(input.fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else { throw Failure.unreadable }
        let size = Int64(metadata.st_size)
        guard size <= maximumBytes else { throw Failure.tooLarge }
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { return destination }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".copy-\(UUID().uuidString).partial")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.storage }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
            var copied: Int64 = 0
            var lastReport: TimeInterval = 0
            progress(TransferProgress(receivedBytes: 0, totalBytes: size))
            while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try checkCancellation()
                guard Int64(chunk.count) <= maximumBytes - copied else { throw Failure.tooLarge }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport >= 0.1 {
                    lastReport = now
                    progress(TransferProgress(receivedBytes: copied, totalBytes: size))
                }
            }
            guard copied == size else { throw Failure.changed }
            try output.synchronize()
            if metadata.st_mode & S_IXUSR != 0 { _ = fchmod(descriptor, S_IRUSR | S_IWUSR | S_IXUSR) }
            try output.close()
            try checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            progress(TransferProgress(receivedBytes: copied, totalBytes: size))
            return destination
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.storage
        }
    }

    /// Incomplete copies cannot survive a process launch. Called only when the
    /// owning store starts, before any new copy can be active.
    static func removeAbandonedPartials(in directory: URL) {
        for file in StorageUsage.files(in: directory, extensions: ["partial"])
        where file.lastPathComponent.hasPrefix(".copy-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
