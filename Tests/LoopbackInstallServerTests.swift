import Darwin
import Foundation
import Testing
@testable import ForgeSignUISim

@Suite("Loopback install HTTP", .timeLimit(.minutes(1)))
struct LoopbackInstallServerTests {
    private struct SocketFailure: Error { let operation: String; let code: Int32 }

    private func request(port: UInt16, text: String, delay: Bool = false,
                         onHeaders: (@Sendable () -> Void)? = nil) async throws -> Data {
        try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketFailure(operation: "socket", code: errno) }
            defer { close(fd) }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            if onHeaders != nil {
                var receiveBuffer: Int32 = 4_096
                setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
            }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { throw SocketFailure(operation: "connect", code: errno) }
            // TCP acceptance can precede the request, and headers can arrive
            // in separate packets. Neither condition should close the socket.
            if delay { try await Task.sleep(nanoseconds: 150_000_000) }
            let bytes = Array(text.utf8)
            let split = delay ? bytes.count - 2 : bytes.count
            for chunk in [Array(bytes[..<split]), Array(bytes[split...])] where !chunk.isEmpty {
                let sent = chunk.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                guard sent == chunk.count else { throw SocketFailure(operation: "send", code: errno) }
                if delay { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            var response = Data()
            var notified = false
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count == 0 { break }
                guard count > 0 else { throw SocketFailure(operation: "receive", code: errno) }
                response.append(contentsOf: buffer[..<count])
                if !notified, response.range(of: Data("\r\n\r\n".utf8)) != nil {
                    notified = true
                    onHeaders?()
                }
            }
            return response
        }.value
    }

    @Test("A client can connect before sending fragmented health headers")
    func delayedHeaders() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString).ipa")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = LocalInstallServer()
        let port = try await server.start(ipa: file, bundleId: "com.example.test", bundleVersion: "1", title: "Test")
        defer { server.stop() }
        let response = try await request(port: port, text: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", delay: true)
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.hasSuffix("\r\n\r\nok"))
    }

    @Test("The server returns exactly the requested IPA bytes")
    func rangedDownload() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString).ipa")
        let payload = Data((0..<262_144).map { UInt8($0 % 251) })
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = LocalInstallServer()
        let port = try await server.start(ipa: file, bundleId: "com.example.test", bundleVersion: "1", title: "Test")
        defer { server.stop() }
        let response = try await request(port: port, text: "GET /app.ipa HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=8192-196607\r\n\r\n")
        let boundary = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let headers = String(decoding: response[..<boundary.lowerBound], as: UTF8.self)
        #expect(headers.hasPrefix("HTTP/1.1 206 Partial Content"))
        #expect(Data(response[boundary.upperBound...]) == payload.subdata(in: 8_192..<196_608))
    }

    @Test("Stopping an active transfer does not send the remaining IPA")
    func cancelledTransfer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("http-\(UUID().uuidString).ipa")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let length: UInt64 = 16 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: length)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }
        let server = LocalInstallServer()
        let port = try await server.start(ipa: file, bundleId: "com.example.test", bundleVersion: "1", title: "Test")
        defer { server.stop() }
        let response = try await request(port: port, text: "GET /app.ipa HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") {
            server.stop()
        }
        let boundary = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        #expect(response.count - boundary.upperBound < length)
    }
}
