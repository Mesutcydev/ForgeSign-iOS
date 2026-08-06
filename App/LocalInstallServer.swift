import Foundation
import Darwin
import os

/// A minimal local HTTP server that serves a signed IPA plus an `itms-services`
/// manifest so iOS will install the app directly on-device.
///
/// iOS OTA installation normally requires HTTPS manifests, but it accepts
/// plain HTTP for localhost — the same loopback behaviour the App Store /
/// AltStore-type installers rely on. The manifest and IPA are therefore served
/// as `http://127.0.0.1:<port>/...` on this app's own loopback address.
///
/// NOTE on the transport stack: this server deliberately uses plain BSD
/// sockets (socket/bind/listen/accept) instead of Network.framework's
/// `NWListener`. On recent iOS releases an `NWListener` backed by bare
/// `NWParameters()` fails to start with `POSIXErrorCode 22 (EINVAL)` — "Install
/// failed: … NWError error 22" — while raw sockets bind and listen without
/// trouble. The original (working) build of ForgeSign used the same raw-socket
/// approach, so this implementation mirrors it.
///
/// NOTE on TLS: the previous implementation served these over HTTPS using the
/// embedded `*.backloop.dev` identity. That certificate now chains to Let's
/// Encrypt's new `ISRG Root YR` root, which older iOS trust stores do not
/// include, so the installer aborted the manifest fetch with a TLS error. Plain
/// loopback HTTP has no certificate-dependency and works on every iOS version.
///
/// Flow: ForgeSign signs the IPA, starts this server, then opens
/// `itms-services://?action=download-manifest&url=http://127.0.0.1:<port>/manifest.plist`.
final class LocalInstallServer: @unchecked Sendable {
    private struct State {
        var listenerFD: Int32 = -1
        var running = false
        var port: UInt16 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private var ipaURL: URL?
    private var bundleId = ""
    private var bundleVersion = "1.0"
    private var title = "App"

    /// Base URL (scheme+host+port) the installer uses to reach this server.
    /// The manifest and IPA are served over loopback plain HTTP so the fetch
    /// carries no TLS/trust dependency (see the header for why that matters).
    var installBaseURL: String {
        "http://127.0.0.1:\(port)"
    }

    var manifestURL: String {
        "\(installBaseURL)/manifest.plist"
    }

    var port: UInt16 {
        state.withLock { $0.port }
    }

    /// Starts the server and returns the bound port.
    func start(ipa: URL, bundleId: String, bundleVersion: String, title: String) async throws -> UInt16 {
        self.ipaURL = ipa
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion.isEmpty ? "1.0" : bundleVersion
        self.title = title

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Never let a send to a vanished connection raise SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral port, read back via getsockname
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &boundAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
        }
        let boundPort = UInt16(boundAddr.sin_port.bigEndian)

        state.withLock { $0.listenerFD = fd; $0.port = boundPort; $0.running = true }

        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "forgesign.installserver"
        t.start()

        return boundPort
    }

    func stop() {
        let fd = state.withLock { state -> Int32 in
            state.running = false
            let fd = state.listenerFD
            state.listenerFD = -1
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    // MARK: Accept loop

    private func acceptLoop(_ fd: Int32) {
        while true {
            let shouldRun = state.withLock { $0.running }
            guard shouldRun else { break }

            // Non-blocking accept with a short sleep keeps the loop stoppable.
            let client = accept(fd, nil, nil)
            if client >= 0 {
                handleConnection(client)
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        // Read request head (up to 64 KiB) until \r\n\r\n.
        var buffer = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 64 * 1024 {
            let n = recv(fd, &raw, raw.count, 0)
            if n <= 0 { return }
            buffer.append(contentsOf: raw[0..<n])
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
              let request = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) else {
            return
        }

        let lines = request.split(separator: "\r\n").map(String.init)
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "GET"
        let path = parts.count > 1 ? parts[1] : "/"
        let headOnly = method == "HEAD"

        if path.hasPrefix("/manifest.plist") {
            sendResponse(fd, status: "200 OK", contentType: "application/xml", body: manifestData(), headOnly: headOnly)
        } else if path.hasPrefix("/app.ipa") {
            if let ipa = ipaURL, FileManager.default.fileExists(atPath: ipa.path) {
                sendFile(fd, url: ipa, headOnly: headOnly)
            } else {
                sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
            }
        } else if path.hasPrefix("/install") {
            // Fallback for iOS versions where opening itms-services:// directly
            // from an app is gated: Safari lands here and is redirected into
            // the installer by the script below.
            sendResponse(fd, status: "200 OK", contentType: "text/html", body: Data(installPage().utf8), headOnly: false)
        } else {
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8), headOnly: false)
        }
    }

    /// Called on the server thread after the IPA has been fully streamed.
    var onIPADelivered: (() -> Void)?

    private func sendAll(_ fd: Int32, _ data: Data) {
        var sent = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func sendResponse(_ fd: Int32, status: String, contentType: String, body: Data, headOnly: Bool) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        if !headOnly { response.append(body) }
        sendAll(fd, response)
    }

    private func sendFile(_ fd: Int32, url: URL, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data(), headOnly: false)
            return
        }
        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Length: \(fileSize)\r\n"
        header += "Connection: close\r\n\r\n"
        sendAll(fd, Data(header.utf8))
        if headOnly {
            try? handle.close()
            return
        }
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            sendAll(fd, chunk)
        }
        try? handle.close()
        onIPADelivered?()
    }

    private func installPage() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Installing \(title)</title>
        <style>body{font-family:-apple-system,sans-serif;color:#1c1c1e;margin:0;min-height:100vh;
        display:flex;justify-content:center;align-items:center;background:#f7f9fd;overflow:hidden}
        .bloom{position:fixed;border-radius:50%;filter:blur(70px);pointer-events:none;z-index:0}
        .b1{width:80vw;height:80vw;background:rgba(0,122,255,.14);top:-30vw;left:-25vw}
        .b2{width:65vw;height:65vw;background:rgba(107,199,184,.14);bottom:-20vw;right:-18vw}
        .card{position:relative;z-index:1;background:rgba(255,255,255,.55);
        backdrop-filter:blur(24px) saturate(1.5);-webkit-backdrop-filter:blur(24px) saturate(1.5);
        border:1px solid rgba(0,0,0,.08);border-radius:22px;padding:28px 24px;max-width:320px;
        text-align:center;box-shadow:0 18px 40px rgba(0,0,0,.12)}
        h1{font-size:18px;font-weight:600;margin:0 0 6px}
        p{font-size:14px;color:#6d6d72;margin:0}
        a{display:inline-block;margin-top:16px;padding:12px 28px;border-radius:14px;color:#fff;
        background:linear-gradient(135deg,#338fff 0%,#0066e6 100%);text-decoration:none;
        font-weight:600;font-size:15px;box-shadow:0 8px 16px rgba(0,122,255,.28)}
        @media (prefers-color-scheme:dark){
        body{background:#242830;color:#ededef}
        .b1{background:rgba(56,153,255,.18)}.b2{background:rgba(107,199,184,.13)}
        .card{background:rgba(255,255,255,.10);border-color:rgba(255,255,255,.15)}
        p{color:#b4b4ba}}
        </style>
        </head>
        <body><div class="bloom b1"></div><div class="bloom b2"></div><div class="card">
        <h1>Installing \(title)…</h1>
        <p>Accept the prompt to start the install.</p>
        <a href="\(itmsServicesURL)">Install again</a>
        </div>
        <script>window.location = "\(itmsServicesURL)";</script>
        </body></html>
        """
    }

    var itmsServicesURL: String {
        let manifest = "\(installBaseURL)/manifest.plist"
        // Keep the URL readable (like Feather does) while still escaping any
        // character that would break the outer query string.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/:")
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: allowed) ?? manifest
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    // MARK: Manifest

    private func manifestData() -> Data {
        let ipaURLString = "\(installBaseURL)/app.ipa"
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(ipaURLString)</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(bundleId)</string>
                        <key>bundle-version</key>
                        <string>\(bundleVersion)</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(title)</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Data(manifest.utf8)
    }
}
