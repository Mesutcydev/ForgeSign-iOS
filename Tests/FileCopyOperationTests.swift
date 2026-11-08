import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Atomic background copies")
struct FileCopyOperationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A multi-chunk copy atomically replaces the destination")
    func replacement() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.ipa")
        let destination = base.appendingPathComponent("input.ipa")
        let data = Data(repeating: 0x6f, count: 3 * 1_024 * 1_024 + 7)
        try data.write(to: source)
        try Data("old input".utf8).write(to: destination)
        _ = try await FileCopyOperation().copy(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == data)
        #expect(try Data(contentsOf: source) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).count == 2)
    }

    @Test("A rejected copy preserves existing bytes and leaves no partial")
    func budget() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.ipa")
        let destination = base.appendingPathComponent("input.ipa")
        try Data(repeating: 7, count: 4_096).write(to: source)
        let previous = Data("keep me".utf8)
        try previous.write(to: destination)
        await #expect(throws: FileCopyOperation.Failure.tooLarge) {
            try await FileCopyOperation().copy(from: source, to: destination, maximumBytes: 1_024)
        }
        #expect(try Data(contentsOf: destination) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).count == 2)
    }

    @Test("Cancelling after a chunk preserves the previous destination")
    func cancellation() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.ipa")
        let destination = base.appendingPathComponent("input.ipa")
        try Data(repeating: 7, count: 4 * 1_024 * 1_024).write(to: source)
        let previous = Data("keep me".utf8)
        try previous.write(to: destination)
        let holder = CopyHolder()
        let operation = FileCopyOperation { progress in
            if progress.receivedBytes > 0 { holder.operation?.cancel() }
        }
        holder.operation = operation
        defer { holder.operation = nil }
        await #expect(throws: CancellationError.self) {
            try await operation.copy(from: source, to: destination)
        }
        #expect(try Data(contentsOf: destination) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).count == 2)
    }

    @Test("Startup cleanup removes only abandoned copy files")
    func cleanup() throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in [".copy-a.partial", "other.partial", "source.ipa"] {
            try Data([1]).write(to: base.appendingPathComponent(name))
        }
        FileCopyOperation.removeAbandonedPartials(in: base)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: base.path)) == ["other.partial", "source.ipa"])
    }
}

private final class CopyHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FileCopyOperation?
    var operation: FileCopyOperation? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
